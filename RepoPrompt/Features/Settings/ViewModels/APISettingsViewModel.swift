import SwiftUI
import Combine

#if DEBUG
private var apiSettingsViewModelDebugLoggingEnabled = false
private func apiSettingsViewModelDebugLog(_ message: @autoclosure () -> String) {
	guard apiSettingsViewModelDebugLoggingEnabled else { return }
	print("[APISettingsViewModel] \(message())")
}
#else
private func apiSettingsViewModelDebugLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - Custom Provider Validation Errors

enum CustomProviderValidationError: Error, LocalizedError {
	case modelTestFailed(model: String, underlyingError: Error? = nil)
	case endpointError(endpoint: String, error: CustomOpenAIProviderError)
	case noModelsAvailable(endpoint: String)
	case networkError(Error)

	var errorDescription: String? {
		switch self {
		case .modelTestFailed(let model, let underlying):
			if let error = underlying {
				return "Failed to validate model '\(model)': \(friendlyErrorDescription(error))"
			}
			return "Model '\(model)' did not respond correctly to test prompt"

		case .endpointError(let endpoint, let error):
			return "Request to \(endpoint) failed: \(friendlyProviderErrorDescription(error))"

		case .noModelsAvailable(let endpoint):
			return "No models returned from \(endpoint). The endpoint may not support the /models API."

		case .networkError(let error):
			return "Network error: \(friendlyErrorDescription(error))"
		}
	}

	private func friendlyProviderErrorDescription(_ error: CustomOpenAIProviderError) -> String {
		switch error {
		case .invalidToken(let statusCode, let message):
			return "Authentication failed (HTTP \(statusCode)). Please check your API key. \(message)"
		case .invalidModel(let statusCode, let message):
			return "Invalid model (HTTP \(statusCode)). \(message)"
		case .requestFailed(let statusCode, let message):
			return "Request failed (HTTP \(statusCode)). \(message)"
		case .invalidResponse(let statusCode, let message):
			return "Invalid response (HTTP \(statusCode)). \(message)"
		case .streamingNotSupported(let statusCode, let message):
			return "Streaming not supported (HTTP \(statusCode)). \(message)"
		case .rateLimitExceeded(let statusCode, let message):
			return "Rate limit exceeded (HTTP \(statusCode)). \(message)"
		case .serverError(let statusCode, let message):
			return "Server error (HTTP \(statusCode)). \(message)"
		case .serviceUnavailable(let statusCode, let message):
			return "Service unavailable (HTTP \(statusCode)). \(message)"
		case .requestTooLarge(let statusCode, let message):
			return "Request too large (HTTP \(statusCode)). \(message)"
		}
	}

	private func friendlyErrorDescription(_ error: Error) -> String {
		// Try to extract useful information from various error types
		if let urlError = error as? URLError {
			switch urlError.code {
			case .notConnectedToInternet:
				return "No internet connection"
			case .cannotFindHost:
				return "Cannot find host - check the URL"
			case .timedOut:
				return "Request timed out"
			case .cannotConnectToHost:
				return "Cannot connect to host"
			default:
				return "Network error: \(urlError.localizedDescription)"
			}
		}

		return error.localizedDescription
	}
}

enum CodexConnectionPhase: Equatable {
	case idle
	case resolvingExecutable
	case executableUnavailable(message: String)
	case refreshingAuth
	case authRequired(message: String)
	case testingAppServer
	case loggingIn
	case connected(resolvedExecutable: String?)
	case failed(message: String)
}

enum ClaudeCodeCLIStatus: Equatable {
	case unknown
	case probing
	case binaryMissing(message: String)
	case binaryPresent

	var binaryPresent: Bool {
		switch self {
		case .binaryPresent:
			return true
		case .unknown, .probing, .binaryMissing:
			return false
		}
	}

	var isKnownMissing: Bool {
		if case .binaryMissing = self { return true }
		return false
	}
}

enum ClaudeCompatibleBackendTestResult: Equatable {
	case success(responseTimeMilliseconds: Int)
	case binaryMissing(message: String)
	case backendAuthRejected(message: String)
	case modelNotFound(message: String)
	case networkError(message: String)
	case failed(message: String)

	var isSuccess: Bool {
		if case .success = self { return true }
		return false
	}

	var displayMessage: String {
		switch self {
		case .success(let responseTimeMilliseconds):
			return "Backend reachable — responded in \(responseTimeMilliseconds) ms."
		case .binaryMissing(let message),
			.backendAuthRejected(let message),
			.modelNotFound(let message),
			.networkError(let message),
			.failed(let message):
			return message
		}
	}
}

@MainActor
public class APISettingsViewModel: ObservableObject {
	@Published var openRouterConfig: OpenRouterConfiguration = ProviderConfigurationManager.shared.getOpenRouterConfiguration() {
		didSet {
			ProviderConfigurationManager.shared.saveOpenRouterConfiguration(openRouterConfig)
		}
	}
	@Published var azureBaseURL: String = ""
	@Published var azureApiKey: String = ""
	@Published var azureApiVersion: String = "2025-04-01-preview"
	@Published private(set) var availableAzureModels: [AzureOpenAIConfiguration.ModelDescriptor] = AzureOpenAIProvider.defaultModelDescriptors
	@Published var isAzureKeyValid: Bool = false
	@Published var azureCustomModel: String = UserDefaults.standard.string(forKey: "customModelAzure") ?? ""
	@Published var anthropicApiKey: String = ""
	@Published var openAIApiKey: String = ""
	@Published var openAIBaseURL: String = UserDefaults.standard.string(forKey: "customBaseURLOpenAI") ?? ""
	@Published var isOpenAIBaseURLValid: Bool = false
	@Published var openAIServiceTier: String = UserDefaults.standard.string(forKey: "openAIServiceTier") ?? "auto"
	@Published var openAIShowServiceTierVariants: Bool = UserDefaults.standard.bool(forKey: "openAIShowServiceTierVariants")
	@Published var ollamaURL: String = "http://localhost:11434"
	@Published var customProviderURL: String = ""
	@Published var customProviderApiKey: String = ""
	@Published var isCustomProviderValid: Bool = false
	@Published var availableCustomModels: [String] = []
	// Cached set for quick lookup – avoids repeated UserDefaults decoding
	@Published private(set) var customEnabledModelSet: Set<String> = []
	@Published var customProviderMaxTokensString: String = "8192" // Add the missing property with default
	@Published var customProviderUserModel: String = UserDefaults.standard.string(forKey: "customProviderUserModel") ?? ""
	@Published var customProviderIncludeContentType: Bool = false
	
	@Published var geminiApiKey: String = ""
	@Published var isGeminiKeyValid: Bool = false
	@Published var isAnthropicKeyValid: Bool = false
	@Published var isOpenAIKeyValid: Bool = false
	@Published var isOllamaURLValid: Bool = false
	@Published var isOllamaModelValid: Bool = false
	@Published private(set) var availableModels: [AIModel] = []
	@Published var availableLocalModels: [String] = []
	@AppStorage("ollamaModel") var ollamaModel: String = ""
	
	// NEW:
	@Published var deepSeekApiKey: String = ""
	@Published var isDeepSeekKeyValid: Bool = false
	
	// NEW: Fireworks
	@Published var fireworksApiKey: String = ""
	@Published var isFireworksKeyValid: Bool = false
	
	// NEW: Grok
	@Published var grokApiKey: String = ""
	@Published var isGrokKeyValid: Bool = false
	
	// NEW: Groq
	@Published var groqApiKey: String = ""
	@Published var isGroqKeyValid: Bool = false
	
	// NEW: Z.AI
	@Published var zaiApiKey: String = ""
	@Published var isZaiKeyValid: Bool = false
	
	// Claude Code
	@Published var isClaudeCodeConnected: Bool = UserDefaults.standard.bool(forKey: "ClaudeCodeConnected")
	@Published private(set) var claudeCodeCLIStatus: ClaudeCodeCLIStatus = UserDefaults.standard.bool(forKey: "ClaudeCodeConnected") ? .binaryPresent : .unknown
	@Published var claudeCodeError: String? = nil
	private var claudeCodeLogCollector: CLIProcessLogCollector?

	var isClaudeCodeBinaryPresent: Bool {
		isClaudeCodeConnected || claudeCodeCLIStatus.binaryPresent
	}

	var isClaudeCodeAccountAuthorized: Bool {
		isClaudeCodeConnected
	}

	var hasActiveClaudeCompatibleBackend: Bool {
		ClaudeCodeCompatibleBackendID.allCases.contains { compatibleBackendIsActive($0) }
	}

	var isClaudeFamilyModelProviderAvailable: Bool {
		// Regular chat/oracle Claude Code models still route through the standard
		// Claude Code provider. Compatible backends are agent-mode runtimes, so do
		// not make `.claudeCode` chat models selectable from compatible backend state.
		isClaudeCodeConnected
	}
	// Codex CLI
	@Published var isCodexConnected: Bool = UserDefaults.standard.bool(forKey: "CodexCLIConnected")
	@Published var codexError: String? = nil
	@Published private(set) var codexConnectionPhase: CodexConnectionPhase = UserDefaults.standard.bool(forKey: "CodexCLIConnected") ? .connected(resolvedExecutable: nil) : .idle
	@Published private(set) var availableCodexModels: [CodexAppServerClient.RemoteModel] = []
	private var codexLogCollector: CLIProcessLogCollector?
	// Gemini CLI
	@Published var isGeminiConnected: Bool = UserDefaults.standard.bool(forKey: "GeminiCLIConnected")
	@Published var geminiError: String? = nil
	private var geminiLogCollector: CLIProcessLogCollector?
	// OpenCode CLI / ACP
	@Published var isOpenCodeConnected: Bool = UserDefaults.standard.bool(forKey: "OpenCodeCLIConnected")
	@Published var openCodeError: String? = nil
	@Published private(set) var availableOpenCodeModelOptions: [AgentModelOption] = []
	private var openCodeLogCollector: CLIProcessLogCollector?
	// Cursor CLI / ACP
	@Published var isCursorConnected: Bool = UserDefaults.standard.bool(forKey: "CursorCLIConnected")
	@Published var cursorError: String? = nil
	@Published private(set) var availableCursorModelOptions: [AgentModelOption] = []
	private var cursorLogCollector: CLIProcessLogCollector?
	
	@Published var openRouterApiKey: String = ""
	@Published var isOpenRouterKeyValid: Bool = false
	@Published var customOpenRouterModels: [String] = []
	@Published var validOpenRouterModels: Set<String> = []
	
	// New properties for fetched OpenRouter models
	@Published var fetchedOpenRouterModels: [String] = []
	@Published var openRouterModelsSearchText: String = ""

	// Per-provider custom model strings (persisted to UserDefaults)
	@Published var openAICustomModel: String = UserDefaults.standard.string(forKey: "customModelOpenAI") ?? ""
	@Published var anthropicCustomModel: String = UserDefaults.standard.string(forKey: "customModelAnthropic") ?? ""
	@Published var geminiCustomModel: String = UserDefaults.standard.string(forKey: "customModelGemini") ?? ""
	@Published var deepSeekCustomModel: String = UserDefaults.standard.string(forKey: "customModelDeepSeek") ?? ""
	@Published var fireworksCustomModel: String = UserDefaults.standard.string(forKey: "customModelFireworks") ?? ""
	@Published var grokCustomModel: String = UserDefaults.standard.string(forKey: "customModelGrok") ?? "" // NEW
	@Published var groqCustomModel: String = UserDefaults.standard.string(forKey: "customModelGroq") ?? "" // NEW
	@Published var zaiCustomModel: String = UserDefaults.standard.string(forKey: "customModelZAI") ?? ""
	@Published var isFetchingOpenRouterModels: Bool = false
	@AppStorage("includeDefaultOpenRouterModels") var includeDefaultOpenRouterModels: Bool = true
	
	@Published var isAddingCustomModel = false
	@Published var lastErrorMessage: String?
	
	// NEW – fetched model lists per provider
	@Published var availableOpenAIModels: [String] = []
	@Published var availableDeepSeekModels: [String] = []
	@Published var availableFireworksModels: [String] = []
	@Published var availableGrokModels: [String] = [] // NEW
	@Published var availableGroqModels: [String] = [] // NEW
	@Published var availableZAIModels: [String] = []
	
	// ── Model-list fetch tasks (one per provider) ───────────────────────────
	private var openAIModelsTask:     Task<Void, Never>?
	private var deepSeekModelsTask:   Task<Void, Never>?
	private var fireworksModelsTask:  Task<Void, Never>?
	private var grokModelsTask:       Task<Void, Never>? // NEW
	private var groqModelsTask:       Task<Void, Never>? // NEW
	private var codexModelsTask:      Task<Void, Never>?
	private var openCodeModelsTask:   Task<Void, Never>?
	private var cursorModelsTask:     Task<Void, Never>?
	private var openRouterModelsTask: Task<Void, Never>?
	private var cliConnectionCancellables = Set<AnyCancellable>()
	private var hasLoadedStoredData = false
	private var isLoadingStoredData = false
	private var hasStoredZAIKey = false

	/// Current Claude Code-compatible backend configurations (GLM/Z.ai, Kimi, Custom), keyed by backend ID.
	///
	/// SEARCH-HELPER: Claude-Compatible Backends settings state, compatibleBackendConfigs,
	/// Claude Code GLM mapping edits, Kimi Code settings, Custom Claude-compatible backend
	@Published var compatibleBackendConfigs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig] = [:]

	/// Whether each Claude Code-compatible backend has a stored API secret. For `.glmZAI`
	/// this mirrors the shared Z.ai API provider key; for other backends it reflects
	/// the backend-specific secret in `ClaudeCodeCompatibleBackendStore`.
	@Published var compatibleBackendSecretPresence: [ClaudeCodeCompatibleBackendID: Bool] = [:]
	@Published private(set) var compatibleBackendLastTestResult: [ClaudeCodeCompatibleBackendID: ClaudeCompatibleBackendTestResult] = [:]

	private let compatibleBackendStore: ClaudeCodeCompatibleBackendStore = .shared

	private let defaultZAIModels = ["glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.7-flash", "glm-4.6", "glm-4.5", "glm-4.5-air", "glm-4.5-flash"]

	var agentModeAvailabilityContext: AgentModelCatalog.AvailabilityContext {
		AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: isClaudeCodeConnected,
			codexAvailable: isCodexConnected,
			geminiAvailable: isGeminiConnected,
			openCodeAvailable: isOpenCodeConnected,
			cursorAvailable: isCursorConnected,
			zaiConfigured: compatibleBackendIsActive(.glmZAI),
			kimiConfigured: compatibleBackendIsActive(.kimi),
			customClaudeCompatibleConfigured: compatibleBackendIsActive(.custom)
		)
	}

	var isCodexExecutableUnavailable: Bool {
		if case .executableUnavailable = codexConnectionPhase {
			return true
		}
		return false
	}

	var codexExecutableUnavailableMessage: String? {
		if case .executableUnavailable(let message) = codexConnectionPhase {
			return message
		}
		return nil
	}

	var canAttemptCodexManagedLogin: Bool {
		switch codexConnectionPhase {
		case .resolvingExecutable, .testingAppServer, .loggingIn, .executableUnavailable:
			return false
		case .idle, .refreshingAuth, .authRequired, .connected, .failed:
			return true
		}
	}

	private func installCLIConnectionObservers() {
		Publishers.MergeMany([
			NotificationCenter.default.publisher(for: .claudeCodeConnectionChanged).map { _ in () },
			NotificationCenter.default.publisher(for: .codexConnectionChanged).map { _ in () },
			NotificationCenter.default.publisher(for: .geminiConnectionChanged).map { _ in () },
			NotificationCenter.default.publisher(for: .openCodeConnectionChanged).map { _ in () },
			NotificationCenter.default.publisher(for: .cursorConnectionChanged).map { _ in () }
		])
		.receive(on: DispatchQueue.main)
		.sink { [weak self] _ in
			self?.reloadCLIConnectionFlagsFromDefaults()
		}
		.store(in: &cliConnectionCancellables)
	}

	private func reloadCLIConnectionFlagsFromDefaults() {
		let wasCursorConnected = isCursorConnected
		isClaudeCodeConnected = UserDefaults.standard.bool(forKey: "ClaudeCodeConnected")
		if isClaudeCodeConnected {
			claudeCodeCLIStatus = .binaryPresent
		}
		isCodexConnected = UserDefaults.standard.bool(forKey: "CodexCLIConnected")
		isGeminiConnected = UserDefaults.standard.bool(forKey: "GeminiCLIConnected")
		isOpenCodeConnected = UserDefaults.standard.bool(forKey: "OpenCodeCLIConnected")
		isCursorConnected = UserDefaults.standard.bool(forKey: "CursorCLIConnected")
		guard wasCursorConnected != isCursorConnected else { return }
		if isCursorConnected {
			startCursorModelsSubscriptionIfNeeded(workspacePath: nil)
		} else {
			stopCursorModelsSubscription(clearModels: true)
		}
		Task { await updateAvailableModels() }
	}

	private func publishClaudeCodeGLMAvailability() {
		let didChange = ClaudeCodeGLMIntegration.setConfigured(hasStoredZAIKey)
		compatibleBackendSecretPresence[.glmZAI] = hasStoredZAIKey
		guard didChange else { return }
		NotificationCenter.default.post(name: .claudeCodeGLMAvailabilityChanged, object: nil)
	}

	// MARK: - Claude Code-compatible backends ------------------------------------------------
	// SEARCH-HELPER: Claude Code-compatible backends, GLM/Z.ai preset, Kimi Code preset,
	// Custom Claude-compatible backend, ClaudeCodeCompatibleBackendStore integration

	/// Loads every Claude Code-compatible backend config + secret presence from the store into
	/// the published dictionaries. Safe to call from any context; publishes on the main actor.
	@MainActor
	func loadCompatibleBackendState() async {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		let previousActiveBackends = Set(ClaudeCodeCompatibleBackendID.allCases.filter { compatibleBackendIsActive($0) })
		let store = compatibleBackendStore
		var configs: [ClaudeCodeCompatibleBackendID: ClaudeCodeCompatibleBackendConfig] = [:]
		var presence: [ClaudeCodeCompatibleBackendID: Bool] = [:]
		for id in ClaudeCodeCompatibleBackendID.allCases {
			configs[id] = store.config(for: id)
			if id == .glmZAI {
				presence[id] = hasStoredZAIKey
			} else {
				presence[id] = await store.hasSecret(for: id)
			}
		}
		self.compatibleBackendConfigs = configs
		self.compatibleBackendSecretPresence = presence
		let currentActiveBackends = Set(ClaudeCodeCompatibleBackendID.allCases.filter { compatibleBackendIsActive($0) })
		if previousActiveBackends != currentActiveBackends {
			postCompatibleBackendAvailabilityChanged()
		}
		await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
	}

	/// Returns the cached config if loaded, otherwise falls back to the store snapshot. Never nil.
	func compatibleBackendConfig(for id: ClaudeCodeCompatibleBackendID) -> ClaudeCodeCompatibleBackendConfig {
		if let config = compatibleBackendConfigs[id] {
			return config
		}
		return compatibleBackendStore.config(for: id)
	}

	@discardableResult
	func refreshClaudeCodeBinaryStatus(timeout: TimeInterval = 10) async -> Bool {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		let previousStatus = claudeCodeCLIStatus
		if case .probing = claudeCodeCLIStatus {
			// Avoid turning an in-flight binary probe into a hard block. The caller's
			// concrete launch/test attempt will still surface command-not-found if needed.
			return true
		}
		if isClaudeCodeConnected {
			claudeCodeCLIStatus = .binaryPresent
			notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			return true
		}

		claudeCodeCLIStatus = .probing
		let collector = CLIProcessLogCollector()
		collector.append("Claude Code binary probe started")
		await CLIEnvironmentCache.shared.invalidate()
		var config = CLIProcessConfiguration(
			captureStdoutTailBytes: 16 * 1024,
			captureStderrTailBytes: 16 * 1024
		)
		config.logCollector = collector
		config.ensureAdditionalPaths(CLIPathHints.claudeCode)
		let runner = CLIProcessRunner(config: config)

		do {
			let result = try await runner.run(
				args: ["--version"],
				stdin: nil,
				outputMode: .none,
				timeout: timeout
			)
			collector.append("Claude Code binary probe exited with status \(result.status)")
			await runner.cancelAll()
			guard result.status == 0 else {
				claudeCodeCLIStatus = .binaryMissing(message: Self.claudeCodeBinaryUnavailableMessage(from: result))
				notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
				await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
				return false
			}
			claudeCodeCLIStatus = .binaryPresent
			notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
			return true
		} catch {
			collector.append("Claude Code binary probe failed: \(error.localizedDescription)")
			await runner.cancelAll()
			claudeCodeCLIStatus = .binaryMissing(message: Self.claudeCodeBinaryUnavailableMessage(from: error))
			notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
			return false
		}
	}

	func compatibleBackendStatusLabel(for id: ClaudeCodeCompatibleBackendID) -> String {
		let config = compatibleBackendConfig(for: id)
		let hasSecret = compatibleBackendHasSecret(id)
		if id == .custom && !config.isEnabled { return "Off" }
		if claudeCodeCLIStatus.isKnownMissing { return "Needs Claude CLI" }
		if !hasSecret { return "Needs API key" }
		if !config.isValid { return "Incomplete" }
		if let result = compatibleBackendLastTestResult[id] {
			return result.isSuccess ? "Active · Tested" : "Test failed"
		}
		if compatibleBackendIsActive(id) { return "Ready" }
		return "Not Configured"
	}

	func compatibleBackendCanAttemptTest(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
		let config = compatibleBackendConfig(for: id)
		return config.isEnabled && config.isValid && compatibleBackendHasSecret(id)
	}

	@discardableResult
	func testCompatibleBackendConnection(_ id: ClaudeCodeCompatibleBackendID) async -> ClaudeCompatibleBackendTestResult {
		guard compatibleBackendCanAttemptTest(id) else {
			let result: ClaudeCompatibleBackendTestResult
			if claudeCodeCLIStatus.isKnownMissing {
				result = .binaryMissing(message: currentClaudeCodeBinaryUnavailableMessage)
			} else if !compatibleBackendConfig(for: id).isValid {
				result = .failed(message: "Backend configuration is incomplete.")
			} else {
				result = .failed(message: "Save an API key before testing this backend.")
			}
			compatibleBackendLastTestResult[id] = result
			return result
		}

		let binaryPresent = await refreshClaudeCodeBinaryStatus()
		guard binaryPresent else {
			let result = ClaudeCompatibleBackendTestResult.binaryMissing(message: currentClaudeCodeBinaryUnavailableMessage)
			compatibleBackendLastTestResult[id] = result
			return result
		}

		let provider = ClaudeCodeProvider()
		let start = Date()
		do {
			let ok = try await provider.testCompatibleBackendConnection(id, timeout: 30)
			await provider.dispose()
			let elapsed = max(1, Int(Date().timeIntervalSince(start) * 1000))
			let result: ClaudeCompatibleBackendTestResult = ok
				? .success(responseTimeMilliseconds: elapsed)
				: .failed(message: "Backend test returned an empty response.")
			compatibleBackendLastTestResult[id] = result
			return result
		} catch {
			await provider.dispose()
			let result = Self.compatibleBackendTestResult(from: error)
			compatibleBackendLastTestResult[id] = result
			if case .binaryMissing(let message) = result {
				let previousStatus = claudeCodeCLIStatus
				claudeCodeCLIStatus = .binaryMissing(message: message)
				notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			}
			return result
		}
	}

	private func invalidateCompatibleBackendTestResult(for id: ClaudeCodeCompatibleBackendID) {
		compatibleBackendLastTestResult[id] = nil
	}

	private var currentClaudeCodeBinaryUnavailableMessage: String {
		if case .binaryMissing(let message) = claudeCodeCLIStatus {
			return message
		}
		return "Claude Code CLI isn't installed or isn't on PATH."
	}

	private static func claudeCodeBinaryUnavailableMessage(from result: CLIProcessRunner.Result) -> String {
		if result.timedOut {
			return "Claude Code CLI did not respond to `claude --version` before the timeout. Check that the installed `claude` command can run from Terminal."
		}
		let stderr = String(data: result.stderr.prefix(800), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let stdout = String(data: result.stdout.prefix(800), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let detail = stderr.isEmpty ? stdout : stderr
		guard !detail.isEmpty else {
			return "Claude Code CLI exited with status \(result.status) while running `claude --version`. Check that the installed `claude` command is runnable."
		}
		return "Claude Code CLI is installed but could not run `claude --version` (exit \(result.status)): \(detail)"
	}

	private static func claudeCodeBinaryUnavailableMessage(from error: Error) -> String {
		if let runnerError = error as? CLIProcessRunnerError {
			switch runnerError {
			case .commandNotFound:
				return "Claude Code CLI isn't installed or isn't on PATH."
			case .spawnFailed(let message):
				return "Claude Code CLI couldn't be launched: \(message)"
			case .waitFailed(let message):
				return "Claude Code CLI couldn't be verified: \(message)"
			case .inputEncodingFailed, .inputWriteFailed(_):
				return "Claude Code CLI couldn't be verified. Check that the installed `claude` command is runnable."
			}
		}
		let message = friendlyClaudeCodeErrorMessage(error)
		let lower = message.lowercased()
		if lower.contains("permission denied") {
			return "Permission denied while launching Claude Code CLI. Ensure the `claude` executable is runnable."
		}
		if lower.contains("no such file or directory") || lower.contains("command not found") || lower.contains("not installed") || lower.contains("not in path") {
			return "Claude Code CLI isn't installed or isn't on PATH."
		}
		return "Claude Code CLI couldn't be verified: \(message)"
	}

	private static func compatibleBackendTestResult(from error: Error) -> ClaudeCompatibleBackendTestResult {
		let message = friendlyClaudeCodeErrorMessage(error)
		let lower = message.lowercased()
		if errorLooksLikeClaudeCodeBinaryMissing(error) || lower.contains("not installed") || lower.contains("not in path") {
			return .binaryMissing(message: claudeCodeBinaryUnavailableMessage(from: error))
		}
		if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("invalid api key") || lower.contains("authentication") || lower.contains("auth") {
			return .backendAuthRejected(message: "Backend rejected the API key. Check the key and auth header style.")
		}
		if lower.contains("404") || lower.contains("not found") || lower.contains("model") && lower.contains("missing") || lower.contains("model_not_found") {
			return .modelNotFound(message: "Backend could not find the configured model. Check the slot mapping or backend model settings.")
		}
		if lower.contains("network") || lower.contains("timed out") || lower.contains("timeout") || lower.contains("cannot connect") || lower.contains("cannot find host") || lower.contains("econnreset") || lower.contains("unreachable") {
			return .networkError(message: "Network error while reaching backend: \(message)")
		}
		return .failed(message: message)
	}

	private static func errorLooksLikeClaudeCodeBinaryMissing(_ error: Error) -> Bool {
		if let runnerError = error as? CLIProcessRunnerError,
			case .commandNotFound = runnerError {
			return true
		}
		let message = friendlyClaudeCodeErrorMessage(error).lowercased()
		return message.contains("command not found")
			|| message.contains("no such file or directory")
			|| message.contains("not installed")
			|| message.contains("not in path")
			|| message.contains("permission denied")
			|| message.contains("not executable")
			|| message.contains("couldn't be launched")
			|| message.contains("could not be launched")
	}

	private static func friendlyClaudeCodeErrorMessage(_ error: Error) -> String {
		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidConfiguration(let detail), .invalidResponse(let detail):
				return detail
			case .apiError(let source):
				return source?.localizedDescription ?? providerError.localizedDescription
			default:
				return providerError.localizedDescription
			}
		}
		return error.localizedDescription
	}

	/// Persists a Claude Code-compatible backend config and refreshes availability only if
	/// the active/enabled/valid state or model behavior actually changed. Text-field edits
	/// (display name, slot-mapping IDs) are persisted without re-posting the availability
	/// notification on every keystroke.
	///
	/// - Parameter config: The new config to persist (display name, base URL, auth, model behavior).
	@MainActor
	func saveCompatibleBackendConfig(_ config: ClaudeCodeCompatibleBackendConfig) {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		invalidateCompatibleBackendTestResult(for: config.id)
		let previous = compatibleBackendConfig(for: config.id)
		let wasActive = compatibleBackendIsActive(config.id)
		compatibleBackendStore.saveConfig(config)
		let latest = compatibleBackendStore.config(for: config.id)
		compatibleBackendConfigs[config.id] = latest
		let isActive = compatibleBackendIsActive(config.id)
		// Only refresh availability when the material state changed: enable toggle,
		// validity of base URL / slot mapping, or switching between no-model and slot mapping.
		let materialStateChanged = wasActive != isActive
			|| previous.isEnabled != latest.isEnabled
			|| previous.isValid != latest.isValid
			|| modelBehaviorKind(previous.modelBehavior) != modelBehaviorKind(latest.modelBehavior)
		if materialStateChanged {
			postCompatibleBackendAvailabilityChanged()
			queueClaudeFamilyModelAvailabilityRefreshIfNeeded(previousAvailability: previousAvailability)
		}
	}

	private func modelBehaviorKind(_ behavior: ClaudeCodeCompatibleBackendConfig.ModelBehavior) -> String {
		switch behavior {
		case .noModel: return "noModel"
		case .claudeSlotMapping: return "claudeSlotMapping"
		}
	}

	/// Persists a Claude Code-compatible backend secret. For `.glmZAI` this shares the
	/// `AIProviderType.zAI` key so Z.ai API Provider and GLM stay in sync.
	@MainActor
	func saveCompatibleBackendSecret(
		_ secret: String,
		for id: ClaudeCodeCompatibleBackendID
	) async throws {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		invalidateCompatibleBackendTestResult(for: id)
		let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
		if id == .glmZAI {
			// Share the existing Z.ai API Provider key.
			try await keyManager.saveAPIKey(trimmed, for: .zAI)
			self.zaiApiKey = trimmed
			self.hasStoredZAIKey = !trimmed.isEmpty
			self.isZaiKeyValid = hasStoredZAIKey
			self.availableZAIModels = hasStoredZAIKey ? defaultZAIModels : []
			publishClaudeCodeGLMAvailability()
		} else {
			try await compatibleBackendStore.saveSecret(trimmed, for: id)
			compatibleBackendSecretPresence[id] = !trimmed.isEmpty
		}
		postCompatibleBackendAvailabilityChanged()
		if id == .glmZAI {
			await updateAvailableModels()
		} else {
			await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
		}
	}

	/// Deletes the stored secret for a Claude Code-compatible backend. For `.glmZAI`
	/// this clears the shared Z.ai API Provider key.
	@MainActor
	func deleteCompatibleBackendSecret(
		for id: ClaudeCodeCompatibleBackendID
	) async throws {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		invalidateCompatibleBackendTestResult(for: id)
		if id == .glmZAI {
			try await keyManager.deleteAPIKey(for: .zAI)
			self.hasStoredZAIKey = false
			self.zaiApiKey = ""
			self.isZaiKeyValid = false
			self.availableZAIModels = []
			publishClaudeCodeGLMAvailability()
			self.zaiCustomModel = ""
			UserDefaults.standard.removeObject(forKey: "customModelZAI")
		} else {
			try await compatibleBackendStore.deleteSecret(for: id)
			compatibleBackendSecretPresence[id] = false
		}
		postCompatibleBackendAvailabilityChanged()
		if id == .glmZAI {
			await updateAvailableModels()
			resetPreferredModelIfNeeded(for: .zAI)
		} else {
			await refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: previousAvailability)
		}
	}

	/// Resets a Claude Code-compatible backend config to its preset defaults.
	/// Secrets are left untouched; use `deleteCompatibleBackendSecret(for:)` for those.
	@MainActor
	func resetCompatibleBackendPreset(_ id: ClaudeCodeCompatibleBackendID) {
		let previousAvailability = isClaudeFamilyModelProviderAvailable
		invalidateCompatibleBackendTestResult(for: id)
		compatibleBackendStore.resetConfig(for: id)
		compatibleBackendConfigs[id] = compatibleBackendStore.config(for: id)
		postCompatibleBackendAvailabilityChanged()
		queueClaudeFamilyModelAvailabilityRefreshIfNeeded(previousAvailability: previousAvailability)
	}

	/// Whether the given backend has an API key stored (for Z.ai/GLM this is the shared key).
	func compatibleBackendHasSecret(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
		compatibleBackendSecretPresence[id] ?? false
	}

	/// Whether a backend should be considered active in Agent Mode pickers.
	///
	/// Active = enabled, valid config, secret present (or shared Z.ai key), and configured mirror flag set.
	func compatibleBackendIsActive(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
		guard !claudeCodeCLIStatus.isKnownMissing else { return false }
		let config = compatibleBackendConfig(for: id)
		guard config.isEnabled, config.isValid else { return false }
		guard compatibleBackendHasSecret(id) else { return false }
		// .glmZAI uses the legacy `ClaudeCodeGLMZAIConfigured` mirror through ZAI flow.
		return compatibleBackendStore.isConfigured(id)
	}

	private func postCompatibleBackendAvailabilityChanged() {
		// Reuse the existing .claudeCodeGLMAvailabilityChanged notification to keep pickers,
		// recommendations, and agent-mode view models in sync for every compatible backend.
		NotificationCenter.default.post(name: .claudeCodeGLMAvailabilityChanged, object: nil)
	}

	private func notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: ClaudeCodeCLIStatus) {
		guard previousStatus.isKnownMissing != claudeCodeCLIStatus.isKnownMissing else { return }
		postCompatibleBackendAvailabilityChanged()
	}

	private func queueClaudeFamilyModelAvailabilityRefreshIfNeeded(previousAvailability: Bool) {
		guard previousAvailability != isClaudeFamilyModelProviderAvailable else { return }
		Task { await self.updateAvailableModels() }
	}

	private func refreshClaudeFamilyModelAvailabilityIfNeeded(previousAvailability: Bool) async {
		guard previousAvailability != isClaudeFamilyModelProviderAvailable else { return }
		await updateAvailableModels()
	}

	private let aiQueriesService: AIQueriesService
	private let keyManager: KeyManager
	
	init(aiQueriesService: AIQueriesService, keyManager: KeyManager, loadStoredDataOnInit: Bool = true) {
		self.aiQueriesService = aiQueriesService
		self.keyManager = keyManager
		installCLIConnectionObservers()
		if loadStoredDataOnInit {
			Task {
				await self.loadStoredDataIfNeeded()
			}
		}
	}
	
	deinit {
		openAIModelsTask?.cancel()
		deepSeekModelsTask?.cancel()
		fireworksModelsTask?.cancel()
		grokModelsTask?.cancel() // NEW
		groqModelsTask?.cancel()
		codexModelsTask?.cancel()
		openCodeModelsTask?.cancel()
		cursorModelsTask?.cancel()
		openRouterModelsTask?.cancel()
	}
	
	@MainActor
	public func loadStoredData() async {
		// Ensure includeDefaultOpenRouterModels is loaded from UserDefaults
		self.includeDefaultOpenRouterModels = UserDefaults.standard.bool(forKey: "includeDefaultOpenRouterModels")
		await loadAllKeys()  // returns immediately; fetch tasks run in background
		hasLoadedStoredData = true
		isLoadingStoredData = false
	}
	
	/// Loads stored data and calls the completion handler after models are fully updated
	@MainActor
	public func loadStoredDataWithCompletion(_ completion: @escaping () -> Void) async {
		// Ensure includeDefaultOpenRouterModels is loaded from UserDefaults
		self.includeDefaultOpenRouterModels = UserDefaults.standard.bool(forKey: "includeDefaultOpenRouterModels")
		await loadAllKeys()
		hasLoadedStoredData = true
		isLoadingStoredData = false
		completion()  // fires while background fetches still run
	}

	@MainActor
	public func loadStoredDataIfNeeded() async {
		guard !hasLoadedStoredData, !isLoadingStoredData else { return }
		isLoadingStoredData = true
		await loadStoredData()
	}
	
	// MARK: - Stored keys / configuration --------------------------------------------------------------
	@MainActor
	public func loadAllKeys() async {
		// ── 0. Cancel previous background fetches ───────────────────────────────
		openAIModelsTask?.cancel();     openAIModelsTask     = nil
		deepSeekModelsTask?.cancel();   deepSeekModelsTask   = nil
		fireworksModelsTask?.cancel();  fireworksModelsTask  = nil
		grokModelsTask?.cancel();       grokModelsTask       = nil // NEW
		groqModelsTask?.cancel();       groqModelsTask       = nil // NEW
		codexModelsTask?.cancel();      codexModelsTask      = nil
		openCodeModelsTask?.cancel();   openCodeModelsTask   = nil
		openRouterModelsTask?.cancel(); openRouterModelsTask = nil
		openRouterConfig = ProviderConfigurationManager.shared.getOpenRouterConfiguration()
		
		do {
			//----------------------------------------------------------------
			// 1. Fetch tokens from KeyManager  (local vars prefixed with `stored`)
			//----------------------------------------------------------------
			let storedAnthropicKey      = (try await keyManager.getAPIKey(for: .anthropic))      ?? ""
			let storedOpenAIKey         = (try await keyManager.getAPIKey(for: .openAI))         ?? ""
			let storedOllamaURL         = (try await keyManager.getAPIKey(for: .ollama))         ?? ""
			let storedOpenRouterKey     = (try await keyManager.getAPIKey(for: .openRouter))     ?? ""
			let storedGeminiKey         = (try await keyManager.getAPIKey(for: .gemini))         ?? ""
			let storedDeepSeekKey       = (try await keyManager.getAPIKey(for: .deepseek))       ?? ""
			let storedFireworksKey      = (try await keyManager.getAPIKey(for: .fireworks))      ?? ""
			let storedGrokKey           = (try await keyManager.getAPIKey(for: .grok))           ?? "" // NEW
			let storedGroqKey           = (try await keyManager.getAPIKey(for: .groq))           ?? "" // NEW
			let storedZAIKey            = (try await keyManager.getAPIKey(for: .zAI))            ?? ""
			let storedCustomProviderKey = (try await keyManager.getAPIKey(for: .customProvider)) ?? "" // NEW
			let storedAzureConfigJSON   = (try await keyManager.getAPIKey(for: .azure))          ?? ""
			
			//----------------------------------------------------------------
			// 2. Restore user-added OpenRouter custom models
			//----------------------------------------------------------------
			let storedCustomModels = UserDefaults.standard
				.stringArray(forKey: "CustomOpenRouterModels") ?? []
			
			self.customOpenRouterModels = storedCustomModels
			
			let prefix = "openrouter_custom_"
			self.validOpenRouterModels = Set(
				storedCustomModels.map { model in
					model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
				}
			)
			
			//----------------------------------------------------------------
			// 3. Restore saved Ollama local models
			//----------------------------------------------------------------
			let storedLocalModels = UserDefaults.standard
				.stringArray(forKey: "OllamaLocalModels") ?? []
			
			//----------------------------------------------------------------
			// 4. Restore Azure configuration
			//----------------------------------------------------------------
			if !storedAzureConfigJSON.isEmpty,
				let data = storedAzureConfigJSON.data(using: .utf8),
				let config = try? JSONDecoder().decode(AzureOpenAIConfiguration.self, from: data) {
				self.azureBaseURL = config.baseURL.absoluteString
				self.azureApiKey = config.apiKey
				self.azureApiVersion = config.apiVersion
				self.availableAzureModels = AzureOpenAIProvider.mergedWithDefaultDescriptors(config.models)
				self.isAzureKeyValid = !config.apiKey.isEmpty
				if !config.models.isEmpty {
					let selectionExists = config.models.contains { $0.id == self.azureCustomModel }
					if !selectionExists {
						self.azureCustomModel = ""
						UserDefaults.standard.removeObject(forKey: "customModelAzure")
					}
				}
				Task {
					await self.updateAzureModels()
				}
			}
			
			//----------------------------------------------------------------
			// 5. Push fetched values into @Published state
			//----------------------------------------------------------------
			anthropicApiKey        = storedAnthropicKey
			isAnthropicKeyValid    = !storedAnthropicKey.isEmpty
			
			openAIApiKey           = storedOpenAIKey
			isOpenAIKeyValid       = !storedOpenAIKey.isEmpty
			
			ollamaURL              = storedOllamaURL.isEmpty ? "http://localhost:11434" : storedOllamaURL
			isOllamaURLValid       = !storedOllamaURL.isEmpty
			
			openRouterApiKey       = storedOpenRouterKey
			isOpenRouterKeyValid   = !storedOpenRouterKey.isEmpty
			
			geminiApiKey           = storedGeminiKey
			isGeminiKeyValid       = !storedGeminiKey.isEmpty
			
			deepSeekApiKey         = storedDeepSeekKey
			isDeepSeekKeyValid     = !storedDeepSeekKey.isEmpty
			
			fireworksApiKey        = storedFireworksKey
			isFireworksKeyValid   = !storedFireworksKey.isEmpty
			
			grokApiKey             = storedGrokKey
			isGrokKeyValid         = !storedGrokKey.isEmpty // NEW
			
			groqApiKey             = storedGroqKey
			isGroqKeyValid         = !storedGroqKey.isEmpty // NEW
			
			hasStoredZAIKey        = !storedZAIKey.isEmpty
			zaiApiKey              = storedZAIKey
			isZaiKeyValid          = hasStoredZAIKey
			availableZAIModels     = isZaiKeyValid ? defaultZAIModels : []
			publishClaudeCodeGLMAvailability()
			
			// Load Claude Code connection state
			isClaudeCodeConnected = UserDefaults.standard.bool(forKey: "ClaudeCodeConnected")
			if isClaudeCodeConnected {
				claudeCodeCLIStatus = .binaryPresent
			}
			// Load Codex CLI connection state
			isCodexConnected = UserDefaults.standard.bool(forKey: "CodexCLIConnected")
			// Load Gemini CLI connection state
			isGeminiConnected = UserDefaults.standard.bool(forKey: "GeminiCLIConnected")
			// Load OpenCode CLI connection state
			isOpenCodeConnected = UserDefaults.standard.bool(forKey: "OpenCodeCLIConnected")
			
			// ── 5.a  Custom Provider -------------------------------------------------
			customProviderApiKey = storedCustomProviderKey  // may be empty
			if let customConfig = try? CustomProviderConfiguration.load() {
				// Reconstruct full URL with version for UI display
				if let version = customConfig.apiVersion, !version.isEmpty {
					customProviderURL = "\(customConfig.url)/\(version)"
				} else {
					customProviderURL = customConfig.url
				}
				availableCustomModels         = Array(customConfig.enabledModels).sorted()
				customEnabledModelSet         = customConfig.enabledModels
				customProviderMaxTokensString = String(customConfig.maxTokens ?? 8192)
				customProviderIncludeContentType = customConfig.includeContentTypeHeader
				isCustomProviderValid         = true            // ← accept even if key is empty
			} else {
				customProviderURL             = ""
				availableCustomModels         = []
				customEnabledModelSet         = []
				customProviderMaxTokensString = "8192"
				isCustomProviderValid         = false
			}
			self.customProviderUserModel = UserDefaults.standard.string(forKey: "customProviderUserModel") ?? ""
			if !self.customProviderUserModel.isEmpty {
				// updateAvailableModels will handle inserting the model
			}
			
			availableLocalModels   = storedLocalModels
			isOllamaModelValid     = !storedLocalModels.isEmpty
		} catch {
			//----------------------------------------------------------------
			// Fallback: wipe state on failure so UI stays consistent
			//----------------------------------------------------------------
			print("Error retrieving stored data: \(error.localizedDescription)")
			
			anthropicApiKey          = "";  isAnthropicKeyValid   = false
			openAIApiKey             = "";  isOpenAIKeyValid      = false
			ollamaURL                = "http://localhost:11434"
			isOllamaURLValid         = false; isOllamaModelValid  = false
			openRouterApiKey         = "";  isOpenRouterKeyValid  = false
			geminiApiKey             = "";  isGeminiKeyValid      = false
			deepSeekApiKey           = "";  isDeepSeekKeyValid    = false
			fireworksApiKey          = "";  isFireworksKeyValid   = false
			grokApiKey               = "";  isGrokKeyValid        = false
			hasStoredZAIKey          = false
			zaiApiKey                = "";  isZaiKeyValid         = false
			availableZAIModels       = []
			publishClaudeCodeGLMAvailability()
			azureBaseURL             = "";  azureApiKey           = ""
			azureApiVersion          = "2025-04-01-preview"
			availableAzureModels     = AzureOpenAIProvider.defaultModelDescriptors;  isAzureKeyValid       = false
			customOpenRouterModels   = [];  validOpenRouterModels = []
			availableLocalModels     = []
			
			// ── Custom Provider fallback ─────────────────────────────────────
			customProviderURL             = ""
			customProviderApiKey          = ""
			isCustomProviderValid         = false
			availableCustomModels         = []
			customProviderMaxTokensString = "8192"
		}
		
		//----------------------------------------------------------------
		// 6. Fire-and-forget model-catalogue fetches (always refresh)
		//----------------------------------------------------------------
		if isOpenAIKeyValid       { openAIModelsTask     = Task { await self.updateOpenAIModels()     } }
		if isDeepSeekKeyValid     { deepSeekModelsTask   = Task { await self.updateDeepSeekModels()   } }
		if isFireworksKeyValid    { fireworksModelsTask  = Task { await self.updateFireworksModels()  } }
		if isGrokKeyValid         { grokModelsTask       = Task { await self.updateGrokModels()       } }
		if isGroqKeyValid         { groqModelsTask       = Task { await self.updateGroqModels()       } } // NEW
		if isCodexConnected       { startCodexModelsSubscriptionIfNeeded() } else { stopCodexModelsSubscription() }
		if isOpenCodeConnected    { startOpenCodeModelsSubscriptionIfNeeded(workspacePath: nil) } else { stopOpenCodeModelsSubscription(clearModels: true) }
		if isCursorConnected      { startCursorModelsSubscriptionIfNeeded(workspacePath: nil) } else { stopCursorModelsSubscription(clearModels: true) }
		if isOpenRouterKeyValid   { openRouterModelsTask = Task { await self.fetchOpenRouterModels()  } }
		if isCustomProviderValid  { Task { await self.fetchCustomModels() } }
		
		//----------------------------------------------------------------
		// 7. Build initial UI list from whatever caches we already have
		//----------------------------------------------------------------
		await updateAvailableModels()

		//----------------------------------------------------------------
		// 8. Load Claude Code-compatible backend state (GLM/Kimi/Custom)
		//----------------------------------------------------------------
		await loadCompatibleBackendState()
	}
	
	// Methods to save custom models explicitly
	func saveOpenAICustomModel() {
		let trimmedModel = openAICustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelOpenAI")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelOpenAI")
		}
		Task {
			await updateAvailableModels()
		}
	}

	func saveOpenAIServiceTier() {
		UserDefaults.standard.set(openAIServiceTier, forKey: "openAIServiceTier")
	}

	func saveOpenAIShowServiceTierVariants() {
		let wasEnabled = UserDefaults.standard.bool(forKey: "openAIShowServiceTierVariants")
		UserDefaults.standard.set(openAIShowServiceTierVariants, forKey: "openAIShowServiceTierVariants")
		
		// When turning variants OFF, normalize saved model preferences to strip tier wrappers
		if wasEnabled && !openAIShowServiceTierVariants {
			normalizeTierVariantPreferences()
		}
		
		Task {
			await updateAvailableModels()
		}
	}
	
	/// Strips tier variant wrappers from saved model preferences when variants are disabled.
	/// This prevents "hidden forced tier" behavior where a tier-variant selection silently
	/// continues to override the global tier even after the user turns off variants.
	private func normalizeTierVariantPreferences() {
		let settingsStore = GlobalSettingsStore.shared
		if let rawValue = settingsStore.planningModelRaw(), !rawValue.isEmpty,
			case .openAIServiceTierVariant(let base, _) = AIModel.fromModelName(rawValue) {
			settingsStore.setPlanningModelRaw(
				base.rawValue,
				reason: "api_settings.normalize_tier_variant.planning",
				honorSync: false
			)
		}

		let normalizedPlanning = settingsStore.planningModelRaw()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if settingsStore.syncChatModelWithOracle(), !normalizedPlanning.isEmpty {
			settingsStore.setPreferredComposeModelRaw(
				normalizedPlanning,
				reason: "api_settings.normalize_tier_variant.preferred_compose.sync_to_planning",
				honorSync: false
			)
		} else if let rawValue = settingsStore.preferredComposeModelRaw(), !rawValue.isEmpty,
			case .openAIServiceTierVariant(let base, _) = AIModel.fromModelName(rawValue) {
			settingsStore.setPreferredComposeModelRaw(
				base.rawValue,
				reason: "api_settings.normalize_tier_variant.preferred_compose",
				honorSync: false
			)
		}
	}
	
	/// One-time migration: consolidate legacy mcpPlanningModel into planningModel.
	/// Call this once at app startup. Safe to call multiple times.
	static func migrateLegacyMCPPlanningModel() {
		let defaults = UserDefaults.standard
		let migrationKey = "didMigrateMCPPlanningModelToPlanningModel"
		
		guard !defaults.bool(forKey: migrationKey) else { return }
		
		let planningModel = GlobalSettingsStore.shared.planningModelRaw() ?? ""
		let mcpPlanningModel = defaults.string(forKey: "mcpPlanningModel") ?? ""
		
		// If planningModel is empty but mcpPlanningModel has a value, migrate it
		if planningModel.isEmpty && !mcpPlanningModel.isEmpty {
			GlobalSettingsStore.shared.setPlanningModelRaw(
				mcpPlanningModel,
				reason: "api_settings.migrate_legacy_mcp_planning_model",
				honorSync: true
			)
		}
		
		// Remove the legacy key
		defaults.removeObject(forKey: "mcpPlanningModel")
		
		// Mark migration as complete
		defaults.set(true, forKey: migrationKey)
	}

	func saveAnthropicCustomModel() {
		let trimmedModel = anthropicCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelAnthropic")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelAnthropic")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveAzureCustomModel() {
		let trimmedModel = azureCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			azureCustomModel = ""
			UserDefaults.standard.removeObject(forKey: "customModelAzure")
		} else {
			azureCustomModel = trimmedModel
			UserDefaults.standard.set(trimmedModel, forKey: "customModelAzure")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveGeminiCustomModel() {
		let trimmedModel = geminiCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelGemini")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelGemini")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveDeepSeekCustomModel() {
		let trimmedModel = deepSeekCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelDeepSeek")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelDeepSeek")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveFireworksCustomModel() {
		let trimmedModel = fireworksCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelFireworks")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelFireworks")
		}
		Task {
			await updateAvailableModels()
		}
	}

	func saveGrokCustomModel() {
		let trimmedModel = grokCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelGrok")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelGrok")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveGroqCustomModel() {
		let trimmedModel = groqCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelGroq")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelGroq")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	func saveZaiCustomModel() {
		let trimmedModel = zaiCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customModelZAI")
		} else {
			UserDefaults.standard.set(trimmedModel, forKey: "customModelZAI")
		}
		Task {
			await updateAvailableModels()
		}
	}
	
	@MainActor
	private var shouldUseResponsesRoutingForOpenAICustomModel: Bool {
		let trimmedBaseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedBaseURL.isEmpty else { return true }
		guard let host = OpenAIURLHelper.splitBaseURLAndVersion(trimmedBaseURL).base?.host?.lowercased() else {
			return false
		}
		return host == "api.openai.com" || host.hasSuffix(".openai.com")
	}

	func updateAvailableModels() async {
		var modelSet = Set<AIModel>()
		
		// ── Key-/token-based providers ─────────────────────────────────────────
		if isAnthropicKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.anthropic))
			if !anthropicCustomModel.isEmpty {
				modelSet.insert(.anthropicCustom(name: anthropicCustomModel))
			}
		}
		
		if isOpenAIKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.openAI))
			if !openAICustomModel.isEmpty {
				if shouldUseResponsesRoutingForOpenAICustomModel {
					modelSet.formUnion(AIModel.openAICustomResponsesVariants(for: openAICustomModel))
				} else {
					modelSet.insert(.openaiCustom(name: openAICustomModel))
				}
			}

			// Generate service tier variants for OpenAI Responses API models when enabled
			if openAIShowServiceTierVariants {
				let baseOpenAIModels = modelSet.filter {
					$0.providerType == .openAI &&
					$0.usesResponsesAPI &&
					!$0.isOpenAIServiceTierVariant
				}
				for base in baseOpenAIModels {
					modelSet.insert(.openAIServiceTierVariant(base: base, tier: "default"))
					modelSet.insert(.openAIServiceTierVariant(base: base, tier: "flex"))
					modelSet.insert(.openAIServiceTierVariant(base: base, tier: "priority"))
				}
			}
		}
		
		if isGeminiKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.gemini))
			if !geminiCustomModel.isEmpty {
				modelSet.insert(.geminiCustom(name: geminiCustomModel))
			}
		}
		
		if isDeepSeekKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.deepseek))
			if !deepSeekCustomModel.isEmpty {
				modelSet.insert(.deepseekCustom(name: deepSeekCustomModel))
			}
		}
		
		if isFireworksKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.fireworks))
			if !fireworksCustomModel.isEmpty {
				modelSet.insert(.fireworksCustom(name: fireworksCustomModel))
			}
		}
		
		if isGrokKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.grok))
			if !grokCustomModel.isEmpty {
				modelSet.insert(.grokCustom(name: grokCustomModel))
			}
		}
		
		if isGroqKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.groq))
			if !groqCustomModel.isEmpty {
				modelSet.insert(.groqCustom(name: groqCustomModel))
			}
		}
		
		if isZaiKeyValid {
			modelSet.formUnion(AIModel.modelsForProvider(.zAI))
			if !zaiCustomModel.isEmpty {
				modelSet.insert(.zaiCustom(name: zaiCustomModel))
			}
		}
		
		if isAzureKeyValid {
			let trimmedSelection = azureCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
			let prioritizedDescriptors = AzureOpenAIProvider.prioritizedDeployments(from: availableAzureModels)
			for descriptor in prioritizedDescriptors {
				modelSet.insert(.azureCustom(name: descriptor.id))
			}
			if !trimmedSelection.isEmpty {
				modelSet.insert(.azureCustom(name: trimmedSelection))
			}
		}
		
		if isOpenRouterKeyValid {
			if includeDefaultOpenRouterModels {
				modelSet.formUnion(AIModel.modelsForProvider(.openRouter))
			}
			modelSet.formUnion(validOpenRouterModels.map { .openrouterCustom(name: $0) })
		}
		
		// ── Claude Code provider ────────────────────────────────
		if isClaudeCodeConnected {
			modelSet.formUnion(AIModel.modelsForProvider(.claudeCode))
		}
		for backendID in ClaudeCodeCompatibleBackendID.allCases where compatibleBackendIsActive(backendID) {
			modelSet.formUnion(ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(backendID))
		}

		if isCodexConnected {
			modelSet.formUnion(AIModel.modelsForProvider(.codex))
		}

		if isGeminiConnected {
			modelSet.formUnion(AIModel.modelsForProvider(.geminiCli))
		}

		if isOpenCodeConnected {
			modelSet.formUnion(AIModel.modelsForProvider(.openCode))
		}

		if isCursorConnected {
			modelSet.formUnion(AIModel.modelsForProvider(.cursor))
		}

		// ── Custom provider (OpenAI compatible) ────────────────────────────────
		if isCustomProviderValid,
			let config = try? CustomProviderConfiguration.load() {
			
			modelSet.formUnion(config.enabledModels.map {
				.customProvider(name: $0, provider: config.name, model: $0)
			})
			if let userModel = config.userPreferredModel, !userModel.isEmpty {
				modelSet.insert(.customProviderUser(name: userModel))
			}
		}
		
		// ── Local Ollama provider ──────────────────────────────────────────────
		if isOllamaURLValid && isOllamaModelValid {
			modelSet.formUnion(AIModel.modelsForProvider(.ollama))
		}
		
		let groupedByProvider = Dictionary(grouping: modelSet, by: \.providerType)
		let sortedProviders = groupedByProvider.keys.sorted(by: AIProviderType.pickerSortPrecedes)
		availableModels = sortedProviders.flatMap { provider in
			AIModel.sortedForPicker(Array(groupedByProvider[provider] ?? []))
		}
	}

	
	func updateOllamaModel(_ newModel: String) {
		self.ollamaModel = newModel
	}

	private func seedPreferredComposeModelIfMissing(_ model: AIModel, reason: String) {
		let settingsStore = GlobalSettingsStore.shared
		let current = settingsStore.preferredComposeModelRaw()?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard current?.isEmpty ?? true else { return }
		let planning = settingsStore.planningModelRaw()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if settingsStore.syncChatModelWithOracle(), !planning.isEmpty {
			settingsStore.setPreferredComposeModelRaw(
				planning,
				reason: "\(reason).sync_to_planning",
				honorSync: false
			)
		} else {
			settingsStore.setPreferredComposeModelRaw(
				model.rawValue,
				reason: reason,
				honorSync: false
			)
		}
	}

	private func providerDiagnosticSuffix(_ provider: AIProviderType) -> String {
		switch provider {
		case .anthropic: return "anthropic"
		case .openAI: return "openai"
		case .gemini: return "gemini"
		case .openRouter: return "openrouter"
		case .deepseek: return "deepseek"
		case .fireworks: return "fireworks"
		case .grok: return "grok"
		case .groq: return "groq"
		case .zAI: return "zai"
		case .customProvider: return "custom"
		case .azure: return "azure"
		case .cursor: return "cursor"
		case .ollama: return "ollama"
		case .claudeCode: return "claude_code"
		case .codex: return "codex"
		case .geminiCli: return "gemini_cli"
		case .openCode: return "opencode"
		}
	}
	
	func validateAndSaveKey(
		key: String,
		for provider: AIProviderType,
		validationFunc: @escaping () async throws -> Bool
	) async throws -> Bool {
		let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
		let isValid = try await validationFunc()
		if isValid {
			try await keyManager.saveAPIKey(trimmedKey, for: provider)
			
			switch provider {
			case .anthropic:
				self.anthropicApiKey = trimmedKey
				self.isAnthropicKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.claude4Sonnet, reason: "api_settings.validate_key.default_seed.anthropic")
			case .openAI:
				self.openAIApiKey = trimmedKey
				self.isOpenAIKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.gpt54Mini, reason: "api_settings.validate_key.default_seed.openai")
			case .gemini:
				self.geminiApiKey = trimmedKey
				self.isGeminiKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.geminiProLatest, reason: "api_settings.validate_key.default_seed.gemini")
			case .ollama:
				self.ollamaURL = trimmedKey
				self.isOllamaURLValid = true
			case .openRouter:
				self.openRouterApiKey = trimmedKey
				self.isOpenRouterKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.openrouterClaude4Sonnet, reason: "api_settings.validate_key.default_seed.openrouter")
			case .azure:
				self.azureBaseURL = ""
				self.azureApiKey = ""
				self.azureApiVersion = "2025-04-01-preview"
				self.availableAzureModels = []
				self.isAzureKeyValid = false
			case .customProvider:
				self.customProviderApiKey = trimmedKey
				self.isCustomProviderValid = true
			case .deepseek:
				self.deepSeekApiKey = trimmedKey
				self.isDeepSeekKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.deepseekChat, reason: "api_settings.validate_key.default_seed.deepseek")
			case .fireworks:
				self.fireworksApiKey = trimmedKey
				self.isFireworksKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.fireworksDeepseekV3p1Terminus, reason: "api_settings.validate_key.default_seed.fireworks")
			case .grok:
				self.grokApiKey = trimmedKey
				self.isGrokKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.grokCodeFast1, reason: "api_settings.validate_key.default_seed.grok")
			case .groq:
				self.groqApiKey = trimmedKey
				self.isGroqKeyValid = true
				seedPreferredComposeModelIfMissing(AIModel.groqKimi, reason: "api_settings.validate_key.default_seed.groq")
			case .zAI:
				invalidateCompatibleBackendTestResult(for: .glmZAI)
				self.hasStoredZAIKey = true
				self.zaiApiKey = trimmedKey
				self.isZaiKeyValid = true
				self.availableZAIModels = defaultZAIModels
				publishClaudeCodeGLMAvailability()
				seedPreferredComposeModelIfMissing(AIModel.zaiGLM5, reason: "api_settings.validate_key.default_seed.zai")
			case .claudeCode:
				break
			case .codex:
				break
			case .geminiCli:
				break
			case .openCode:
				break
			case .cursor:
				break
			}

			await self.updateAvailableModels()
		}
		return isValid
	}
	
	func deleteKey(for provider: AIProviderType) async throws {
		try await keyManager.deleteAPIKey(for: provider)
		switch provider {
		case .anthropic:
			self.anthropicApiKey = ""
			self.isAnthropicKeyValid = false
		case .openAI:
			self.openAIApiKey = ""
			self.isOpenAIKeyValid = false
		case .gemini:
			self.geminiApiKey = ""
			self.isGeminiKeyValid = false
		case .ollama:
			self.ollamaURL = "http://localhost:11434"
			self.isOllamaURLValid = false
		case .openRouter:
			self.openRouterApiKey = ""
			self.isOpenRouterKeyValid = false
		case .azure:
			break
		case .customProvider:
			self.customProviderApiKey = ""
			self.isCustomProviderValid = false
			self.availableCustomModels = []
		case .deepseek:
			self.deepSeekApiKey = ""
			self.isDeepSeekKeyValid = false
		case .fireworks:
			self.fireworksApiKey = ""
			self.isFireworksKeyValid = false
		case .grok:
			self.grokApiKey = ""
			self.isGrokKeyValid = false
		case .groq:
			self.groqApiKey = ""
			self.isGroqKeyValid = false
		case .zAI:
			invalidateCompatibleBackendTestResult(for: .glmZAI)
			self.hasStoredZAIKey = false
			self.zaiApiKey = ""
			self.isZaiKeyValid = false
			self.availableZAIModels = []
			publishClaudeCodeGLMAvailability()
			self.zaiCustomModel = ""
			UserDefaults.standard.removeObject(forKey: "customModelZAI")
		case .claudeCode:
			break
		case .codex:
			break
		case .geminiCli:
			break
		case .openCode:
			break
		case .cursor:
			break
		}
		await self.updateAvailableModels()
		self.resetPreferredModelIfNeeded(for: provider)
	}
	
#if DEBUG
	func test_resetPreferredModelIfNeeded(for provider: AIProviderType) {
		resetPreferredModelIfNeeded(for: provider)
	}

	func test_setClaudeCodeCLIStatus(_ status: ClaudeCodeCLIStatus) {
		let previousStatus = claudeCodeCLIStatus
		claudeCodeCLIStatus = status
		notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
	}
#endif

	private func resetPreferredModelIfNeeded(for provider: AIProviderType) {
		let currentPreferredModel = GlobalSettingsStore.shared.preferredComposeModelRaw() ?? ""
		
		// Define conditions based on provider type
		let condition: (AIModel) -> Bool
		switch provider {
		case .openAI:       condition = { $0.isOpenAIModel }
		case .anthropic:    condition = { $0.isAnthropicModel }
		case .gemini:       condition = { $0.isGeminiModel }
		case .openRouter:   condition = { $0.isOpenRouterModel }
		case .deepseek:     condition = { $0.providerType == .deepseek }
		case .customProvider: condition = { $0.providerType == .customProvider }
		case .azure:        condition = { $0.providerType == .azure }
		case .fireworks:    condition = { $0.providerType == .fireworks }
		case .grok:         condition = { $0.providerType == .grok }
		case .groq:         condition = { $0.providerType == .groq }
		case .zAI:          condition = { $0.providerType == .zAI }
		case .cursor:       condition = { $0.providerType == .cursor }
		default: return // No reset needed for this provider type
		}

		let settingsStore = GlobalSettingsStore.shared
		if let model = AIModel.fromModelName(currentPreferredModel), condition(model) {
			let reasonSuffix = providerDiagnosticSuffix(provider)
			let planningRaw = settingsStore.planningModelRaw()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			let planningModel = AIModel.fromModelName(planningRaw)
			if settingsStore.syncChatModelWithOracle(), !planningRaw.isEmpty, planningModel.map({ !condition($0) }) == true {
				settingsStore.setPreferredComposeModelRaw(
					planningRaw,
					reason: "api_settings.provider_reset.preferred_compose.\(reasonSuffix).sync_to_planning",
					honorSync: false
				)
			} else {
				let replacement = self.availableModels.first(where: { !condition($0) })?.rawValue
				if settingsStore.syncChatModelWithOracle(), planningRaw.isEmpty || planningModel.map(condition) == true {
					settingsStore.setPlanningModelRaw(
						replacement,
						reason: "api_settings.provider_reset.planning.\(reasonSuffix)",
						honorSync: false
					)
				}
				settingsStore.setPreferredComposeModelRaw(
					replacement,
					reason: "api_settings.provider_reset.preferred_compose.\(reasonSuffix)",
					honorSync: false
				)
			}
		}
	}
	
	func validateAnthropicKey() async throws -> Bool {
		let trimmedKey = anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let isValid = try await aiQueriesService.testAnthropicAPI(with: trimmedKey)
		if isValid {
			try await keyManager.saveAPIKey(trimmedKey, for: .anthropic)
		}
		self.isAnthropicKeyValid = isValid
		return isValid
	}
	
	func validateOpenAIKey() async throws -> Bool {
		let trimmed = openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		// Use override if present
		let base = normalizedOpenAIBaseURL(openAIBaseURL)
		let ok = try await aiQueriesService.testOpenAIAPI(with: trimmed,
															baseURL: base.isEmpty ? nil : base)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .openAI)
			self.openAIApiKey = trimmed
			self.isOpenAIKeyValid = true
			await updateOpenAIModels()
		} else { self.isOpenAIKeyValid = false }
		return ok
	}
	
	// SEARCH-HELPER: OpenAI Base URL, Validate Base URL, Custom Endpoint
	@MainActor
	func validateAndSaveOpenAIBaseURL() async throws -> Bool {
		// Parse base and optional version from the user input
		let (baseURLString, version) = normalizedOpenAIBaseURLAndVersion(openAIBaseURL)

		// If no key is present, persist base/version but mark as not validated (old behavior preserved)
		guard !openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			UserDefaults.standard.set(baseURLString, forKey: "customBaseURLOpenAI")
			if let v = version, !v.isEmpty {
				UserDefaults.standard.set(v, forKey: "customOpenAIVersionOverride")
			} else {
				UserDefaults.standard.removeObject(forKey: "customOpenAIVersionOverride")
			}
			self.openAIBaseURL = baseURLString
			self.isOpenAIBaseURLValid = false
			return true
		}

		// Validate using a temporary override that *includes* the version to ensure the probe hits the correct endpoint
		let baseForTest = version.map { "\(baseURLString)/\($0)" } ?? baseURLString
		let ok = try await aiQueriesService.testOpenAIAPI(with: openAIApiKey, baseURL: baseForTest)
		if ok {
			UserDefaults.standard.set(baseURLString, forKey: "customBaseURLOpenAI")
			if let v = version, !v.isEmpty {
				UserDefaults.standard.set(v, forKey: "customOpenAIVersionOverride")
			} else {
				UserDefaults.standard.removeObject(forKey: "customOpenAIVersionOverride")
			}
			self.openAIBaseURL = baseURLString
			self.isOpenAIBaseURLValid = true
			await updateOpenAIModels()
		} else {
			self.isOpenAIBaseURLValid = false
		}
		return ok
	}
	
	// SEARCH-HELPER: Reset OpenAI Base URL, Clear Custom Endpoint
	@MainActor
	func resetOpenAIBaseURL() async {
		UserDefaults.standard.removeObject(forKey: "customBaseURLOpenAI")
		UserDefaults.standard.removeObject(forKey: "customOpenAIVersionOverride")
		self.openAIBaseURL = ""
		self.isOpenAIBaseURLValid = false
		await updateOpenAIModels()
	}
	
	func validateOllamaURL() async throws -> Bool {
		let baseURL = ollamaURL.hasSuffix("/v1") ? ollamaURL : (ollamaURL.hasSuffix("/") ? ollamaURL + "v1" : ollamaURL + "/v1")
		
		let provider = CustomOpenAIProvider(
			baseURL: baseURL,
			apiKey: "",
			defaultModel: "llama2",
			defaultTemperature: 0.7,
			customHeaders: [:]
		)
		
		do {
			let models = try await provider.getAvailableModels()
			self.availableLocalModels = models
			UserDefaults.standard.set(models, forKey: "OllamaLocalModels")
			self.ollamaModel = models.first ?? ""
			self.isOllamaURLValid = true
			self.validateOllamaModel()
			return true
		} catch {
			self.isOllamaURLValid = false
			self.isOllamaModelValid = false
			self.availableLocalModels = []
			UserDefaults.standard.removeObject(forKey: "OllamaLocalModels")
			throw error
		}
	}
	
	func validateOllamaModel() {
		let isValid = !ollamaModel.isEmpty && availableLocalModels.contains(ollamaModel)
		isOllamaModelValid = isValid
		
		if !isValid {
			ollamaModel = ""
			isOllamaModelValid = false
		}
		
		UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
		
		Task {
			await updateAvailableModels()
		}
	}
	
	func addCustomOpenRouterModel(_ inputName: String) {
		Task {
			let prefix = "openrouter_custom_"
			let normalizedName = inputName.hasPrefix(prefix) ? inputName : (prefix + inputName)
			if !customOpenRouterModels.contains(normalizedName) {
				do {
					let rawModelName = String(normalizedName.dropFirst(prefix.count))
					let isValid = try await aiQueriesService.testOpenRouterAPI(
						with: openRouterApiKey,
						model: .openrouterCustom(name: rawModelName)
					)
					if isValid {
						customOpenRouterModels.append(normalizedName)
						validOpenRouterModels.insert(rawModelName)
						UserDefaults.standard.set(customOpenRouterModels, forKey: "CustomOpenRouterModels")
					} else {
						print("The custom model \(normalizedName) is invalid.")
					}
					self.isAddingCustomModel = false
					await updateAvailableModels()
				} catch {
					print("Error testing OpenRouter model: \(error)")
					self.isAddingCustomModel = false
					self.lastErrorMessage = "Failed to add model: \(error.localizedDescription)"
				}
			}
		}
	}
	
	func removeCustomOpenRouterModel(at index: Int) {
		let modelName = customOpenRouterModels[index]
		customOpenRouterModels.remove(at: index)
		validOpenRouterModels.remove(modelName)
		UserDefaults.standard.set(customOpenRouterModels, forKey: "CustomOpenRouterModels")
		Task {
			await updateAvailableModels()
		}
	}
	
	func testOpenRouterModel(_ modelName: String) {
		Task {
			do {
				let isValid = try await aiQueriesService.testOpenRouterAPI(with: openRouterApiKey, model: .openrouterCustom(name: modelName))
				if isValid {
					validOpenRouterModels.insert(modelName)
				} else {
					validOpenRouterModels.remove(modelName)
				}
				await updateAvailableModels()
			} catch {
				print("Error testing OpenRouter model: \(error)")
				validOpenRouterModels.remove(modelName)
				await updateAvailableModels()
			}
		}
	}
	
	func validateOpenRouterKey() async throws -> Bool {
		let trimmedKey = openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedKey.isEmpty else {
			isOpenRouterKeyValid = false
			throw NSError(domain: "OpenRouterValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "OpenRouter API key cannot be empty."
			])
		}
		
		do {
			try await keyManager.saveAPIKey(trimmedKey, for: .openRouter)
			await fetchOpenRouterModels()
			
			if fetchedOpenRouterModels.isEmpty {
				isOpenRouterKeyValid = false
				try? await keyManager.deleteAPIKey(for: .openRouter)
				return false
			} else {
				isOpenRouterKeyValid = true
				return true
			}
		} catch {
			isOpenRouterKeyValid = false
			try? await keyManager.deleteAPIKey(for: .openRouter)
			throw error
		}
	}
	
	// Method to update OpenRouter configuration
	func updateOpenRouterConfig(maxTokens: Int? = nil, useCustomSettings: Bool? = nil) {
		var config = openRouterConfig
		
		if let maxTokens = maxTokens {
			config.baseConfig.maxTokens = maxTokens
		}
		
		if let useCustomSettings = useCustomSettings {
			config.useCustomSettings = useCustomSettings
		}
		
		openRouterConfig = config
	}
	
	// Methods for custom headers
	func setOpenRouterHeader(key: String, value: String) {
		var config = openRouterConfig
		config.customHeaders[key] = value
		openRouterConfig = config
	}
	
	func removeOpenRouterHeader(key: String) {
		var config = openRouterConfig
		config.customHeaders.removeValue(forKey: key)
		openRouterConfig = config
	}
	
	func validateGeminiKey() async throws -> Bool {
		let trimmed = geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testGeminiAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .gemini)
			self.geminiApiKey = trimmed
			self.isGeminiKeyValid = true
		} else { self.isGeminiKeyValid = false }
		return ok
	}
	
	/// NEW:
	func validateDeepSeekKey() async throws -> Bool {
		let trimmed = deepSeekApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testDeepSeekAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .deepseek)
			self.deepSeekApiKey = trimmed
			self.isDeepSeekKeyValid = true
			await updateDeepSeekModels()
		} else { self.isDeepSeekKeyValid = false }
		return ok
	}
	
	/// NEW: Fireworks
	func validateFireworksKey() async throws -> Bool {
		let trimmed = fireworksApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testFireworksAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .fireworks)
			self.fireworksApiKey = trimmed
			self.isFireworksKeyValid = true
			await updateFireworksModels()
		} else { self.isFireworksKeyValid = false }
		return ok
	}

	func validateGrokKey() async throws -> Bool {
		let trimmed = grokApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testGrokAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .grok)
			self.grokApiKey = trimmed
			self.isGrokKeyValid = true
			await updateGrokModels()
		} else { self.isGrokKeyValid = false }
		return ok
	}
	
	func validateGroqKey() async throws -> Bool {
		let trimmed = groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testGroqAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .groq)
			self.groqApiKey = trimmed
			self.isGroqKeyValid = true
			await updateGroqModels()
		} else { self.isGroqKeyValid = false }
		return ok
	}
	
	func validateZAIKey() async throws -> Bool {
		let trimmed = zaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let ok = try await aiQueriesService.testZAIAPI(with: trimmed)
		if ok {
			try await keyManager.saveAPIKey(trimmed, for: .zAI)
			invalidateCompatibleBackendTestResult(for: .glmZAI)
			self.hasStoredZAIKey = true
			self.zaiApiKey = trimmed
			self.isZaiKeyValid = true
			self.availableZAIModels = defaultZAIModels
			publishClaudeCodeGLMAvailability()
			await updateAvailableModels()
		} else {
			self.isZaiKeyValid = false
			self.availableZAIModels = []
			publishClaudeCodeGLMAvailability()
		}
		return ok
	}
	
	// MARK: - Custom Provider (OpenAI-compatible)
	func validateCustomProvider() async throws -> Bool {
		// 0️⃣ Basic validation --------------------------------------------------
		let trimmedURL = customProviderURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedURL.isEmpty else {
			throw CustomProviderValidationError.networkError(
				NSError(domain: "CustomProvider", code: 1, userInfo: [
					NSLocalizedDescriptionKey: "Base URL is required. Please enter your provider's API endpoint."
				])
			)
		}

		// Parse base + optional version
		let split = OpenAIURLHelper.splitBaseURLAndVersion(trimmedURL)
		guard let baseURL = split.base?.absoluteString, !baseURL.isEmpty else {
			throw CustomProviderValidationError.networkError(
				NSError(domain: "CustomProvider", code: 2, userInfo: [
					NSLocalizedDescriptionKey: "Invalid URL format: '\(trimmedURL)'. Please check the URL and try again."
				])
			)
		}
		let detectedVersion = split.version

		// ─── Fetch current config (if any) so we can retain the user's model list
		let existingConfig = try? CustomProviderConfiguration.load()
		let previouslyEnabled = existingConfig?.enabledModels ?? []

		let apiKey  = customProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let userModel = customProviderUserModel.trimmingCharacters(in: .whitespacesAndNewlines)
		let maxTokensValue = Int(customProviderMaxTokensString)

		// 1️⃣ Validate endpoint: either test custom model OR fetch model list
		var fetchedModels: [String] = []

		if !userModel.isEmpty {
			// User specified a model → validate it with a test completion (skip model list fetch)
			let testProvider = OpenAIProvider(
				apiKey: apiKey,
				baseURL: URL(string: baseURL),
				configuredMaxTokens: 16,
				overrideVersion: detectedVersion,
				includeUsageInStream: false
			)

			let testMessage = AIMessage(
				systemPrompt: "You are a helpful assistant.",
				userMessage: "Say hello"
			)

			do {
				let result = try await testProvider.completeMessage(
					testMessage,
					model: .customProviderUser(name: userModel),
					maxTokens: 10
				)
				guard result.text.lowercased().contains("hello") else {
					throw CustomProviderValidationError.modelTestFailed(model: userModel)
				}
			} catch let error as CustomProviderValidationError {
				throw error
			} catch {
				throw CustomProviderValidationError.modelTestFailed(model: userModel, underlyingError: error)
			}
		} else {
			// No custom model → fetch available models to validate endpoint
			let probeProvider = CustomOpenAIProvider(
				baseURL: baseURL,
				apiKey: apiKey,
				defaultModel: "gpt-4o",
				defaultTemperature: 0.7,
				apiVersion: detectedVersion
			)

			do {
				fetchedModels = try await probeProvider.getAvailableModels()
				guard !fetchedModels.isEmpty else {
					throw CustomProviderValidationError.noModelsAvailable(endpoint: "\(baseURL)\(detectedVersion.map { "/\($0)" } ?? "")/models")
				}
			} catch let error as CustomOpenAIProviderError {
				throw CustomProviderValidationError.endpointError(endpoint: "\(baseURL)\(detectedVersion.map { "/\($0)" } ?? "")/models", error: error)
			} catch let error as CustomProviderValidationError {
				throw error
			} catch {
				throw CustomProviderValidationError.networkError(error)
			}
		}

		await MainActor.run { self.availableCustomModels = fetchedModels }

		// 3️⃣ Decide default / preferred model
		let defaultModelToSave: String
		if !userModel.isEmpty {
			// User overrides everything
			defaultModelToSave = userModel
		} else {
			// Mimic legacy behaviour – require at least one model from /models
			guard let first = fetchedModels.first else { throw AIProviderError.invalidModel }
			defaultModelToSave = first
		}

		// 4️⃣ Build configuration ---------------------------------------------
		// Keep only enabled models which still exist (plus the user-override if any)
		var retainedEnabled = previouslyEnabled
		if !fetchedModels.isEmpty {
			retainedEnabled = retainedEnabled.filter { fetchedModels.contains($0) }
		}
		// Ensure the user-preferred model is *not* duplicated in enabledModels
		if !userModel.isEmpty {
			retainedEnabled.remove(userModel)   // remove if present
		}

		let config = try CustomProviderConfiguration(
			url: baseURL,
			defaultModel: defaultModelToSave,
			headers: [:],
			name: "Custom",
			enabledModels: retainedEnabled,                 // ← preserve!
			maxTokens: maxTokensValue,
			userPreferredModel: userModel.isEmpty ? nil : userModel,
			includeContentTypeHeader: customProviderIncludeContentType,
			apiVersion: detectedVersion
		)
		try CustomProviderConfiguration.save(config)

		// Refresh the cached sets so look-ups are instant
		await MainActor.run {
			self.customEnabledModelSet = config.enabledModels
		}

		// 5️⃣ Persist / clear API key like the old implementation --------------
		if apiKey.isEmpty {
			try? await keyManager.deleteAPIKey(for: .customProvider)
		} else {
			try await keyManager.saveAPIKey(apiKey, for: .customProvider)
		}

		// 6️⃣ Update in-memory / UserDefaults ----------------------------------
		await MainActor.run {
			self.customProviderApiKey   = apiKey
			self.customProviderUserModel = userModel      // keep UI in sync
			self.isCustomProviderValid  = true
		}
		if userModel.isEmpty {
			UserDefaults.standard.removeObject(forKey: "customProviderUserModel")
		} else {
			UserDefaults.standard.set(userModel, forKey: "customProviderUserModel")
		}

		await updateAvailableModels()
		return true
	}
	
	func validateAzureSettings() async throws -> Bool {
		let trimmedBase = azureBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedKey = azureApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		let trimmedVersion = azureApiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
		
		guard let normalizedURL = normalizeAzureBaseURL(from: trimmedBase) else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Azure base URL must be provided."
			])
		}
		
		guard !trimmedKey.isEmpty else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Azure API key must be provided."
			])
		}
		
		guard !trimmedVersion.isEmpty else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Azure API version must be provided."
			])
			}
			
		AzureOpenAIProvider.debug("Starting validation for base URL \(normalizedURL.absoluteString) using API version \(trimmedVersion)")
		
		let discoveryVersions = AzureOpenAIProvider.discoveryAPIVersions
		let models = try await AzureOpenAIProvider.discoverDeployments(
			baseURL: normalizedURL,
			apiKey: trimmedKey,
			apiVersions: discoveryVersions
		)
		let resolvedAPIVersion = trimmedVersion
		AzureOpenAIProvider.debug("Retrieved \(models.count) Azure deployments")
		
		guard !models.isEmpty else {
			AzureOpenAIProvider.debug("No deployments returned from Azure")
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "No Azure deployments were returned for this resource."
			])
		}
		
		let trimmedSelection = azureCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
		let selectedDescriptor: AzureOpenAIConfiguration.ModelDescriptor
		if let match = models.first(where: { $0.id == trimmedSelection }) {
			selectedDescriptor = match
		} else if let defaultID = AzureOpenAIProvider.preferredDeploymentID(from: models),
			let fallback = models.first(where: { $0.id == defaultID }) {
			selectedDescriptor = fallback
		} else if let first = models.first {
			selectedDescriptor = first
		} else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Unable to determine a default Azure deployment."
			])
		}
		
		let finalConfig = AzureOpenAIConfiguration(
			baseURL: normalizedURL,
			apiKey: trimmedKey,
			apiVersion: resolvedAPIVersion,
			extraHeaders: nil,
			models: models,
			defaultModelID: selectedDescriptor.id
		)
		
		AzureOpenAIProvider.debug("Testing Azure credentials against deployment \(selectedDescriptor.id) (base model: \(selectedDescriptor.baseModelID ?? "unknown"))")
		
		let validationPassed = try await aiQueriesService.testAzureOpenAIAPI(configuration: finalConfig)
		guard validationPassed else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Azure deployment \(selectedDescriptor.id) did not respond as expected during final validation."
			])
		}
		
		let encoder = JSONEncoder()
		let data = try encoder.encode(finalConfig)
		guard let jsonString = String(data: data, encoding: .utf8) else {
			throw NSError(domain: "AzureValidation", code: -1, userInfo: [
				NSLocalizedDescriptionKey: "Failed to persist Azure configuration."
			])
		}
		
		try await keyManager.saveAPIKey(jsonString, for: .azure)
		
		self.azureBaseURL = normalizedURL.absoluteString
		self.azureApiKey = trimmedKey
		self.azureApiVersion = resolvedAPIVersion
		self.availableAzureModels = AzureOpenAIProvider.mergedWithDefaultDescriptors(models)
		self.isAzureKeyValid = true
		AzureOpenAIProvider.debug("Azure configuration saved and validated for deployment \(selectedDescriptor.id)")
		
		await updateAvailableModels()
		return validationPassed
	}
	
	func deleteAzureKey() async throws {
		try await keyManager.deleteAPIKey(for: .azure)
		self.azureBaseURL = ""
		self.azureApiKey = ""
		self.azureApiVersion = "2025-04-01-preview"
		self.availableAzureModels = AzureOpenAIProvider.defaultModelDescriptors
		self.isAzureKeyValid = false
		self.azureCustomModel = ""
		UserDefaults.standard.removeObject(forKey: "customModelAzure")
		await updateAvailableModels()
	}
	
	private func normalizeAzureBaseURL(from rawValue: String) -> URL? {
		var cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !cleaned.isEmpty else { return nil }
		if !cleaned.lowercased().hasPrefix("http") {
			cleaned = "https://\(cleaned)"
		}
		if cleaned.hasSuffix("/") {
			cleaned.removeLast()
		}
		guard var components = URLComponents(string: cleaned), let host = components.host else {
			return nil
		}
		components.scheme = components.scheme ?? "https"
		components.host = host
		components.path = ""
		return components.url
	}


	@MainActor
	private func updateAzureModels() async {
		let trimmedKey = azureApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard isAzureKeyValid,
			!trimmedKey.isEmpty,
			let normalizedURL = normalizeAzureBaseURL(from: azureBaseURL) else {
			return
		}
		let discoveryVersions = AzureOpenAIProvider.discoveryAPIVersions
		do {
			let descriptors = try await AzureOpenAIProvider.discoverDeployments(
				baseURL: normalizedURL,
				apiKey: trimmedKey,
				apiVersions: discoveryVersions
			)
			self.availableAzureModels = AzureOpenAIProvider.mergedWithDefaultDescriptors(descriptors)
		} catch {
			AzureOpenAIProvider.debug("Azure deployment refresh failed: \(error)")
		}
		await updateAvailableModels()
	}
	
	func deleteCustomProvider() async throws {
		CustomProviderConfiguration.delete()
		try await keyManager.deleteAPIKey(for: .customProvider)

		UserDefaults.standard.removeObject(forKey: "customProviderUserModel")
		self.customProviderUserModel = ""

		self.customProviderURL = ""
		self.customProviderApiKey = ""
		self.isCustomProviderValid = false
		self.availableCustomModels = []
		self.customEnabledModelSet = []
		self.customProviderMaxTokensString = "8192" // Reset to default

		await updateAvailableModels()

		UserDefaults.standard.removeObject(forKey: "CustomProviderSettings")
	}
	
	func fetchCustomModels() async {
		guard !customProviderURL.isEmpty else { return }
		
		do {
			let provider = CustomOpenAIProvider(
				baseURL: customProviderURL,
				apiKey: customProviderApiKey,
				defaultModel: "",
				defaultTemperature: 0.7
			)
			
			let models = try await provider.getAvailableModels()
			self.availableCustomModels = models
		} catch {
			self.availableCustomModels = []
			apiSettingsViewModelDebugLog("Error fetching custom models: \(error)")
		}
	}
	
	// MARK: - Claude Code
	func testClaudeCodeConnection() async throws -> Bool {
		let previousStatus = claudeCodeCLIStatus
		let collector = CLIProcessLogCollector()
		collector.append("Claude Code connection test started")
		self.claudeCodeLogCollector = collector

		collector.append("Refreshing login-shell environment cache")
		await CLIEnvironmentCache.shared.invalidate()

		let provider = ClaudeCodeProvider(logCollector: collector)
		collector.append("Created Claude Code provider for health check")

		do {
			let ok = try await provider.testConnection(timeout: 30)
			collector.append("Health check completed with status: \(ok ? "success" : "empty response")")
			collector.append("Disposing Claude Code provider resources")
			await provider.dispose()
			collector.append("Claude Code provider disposed")
			self.isClaudeCodeConnected = ok
			if ok {
				self.claudeCodeCLIStatus = .binaryPresent
			}
			notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			self.claudeCodeError = nil
			UserDefaults.standard.set(self.isClaudeCodeConnected, forKey: "ClaudeCodeConnected")
			await self.updateAvailableModels()
			NotificationCenter.default.post(
				name: .claudeCodeConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			if ok {
				collector.append("Claude Code marked as connected")
				self.claudeCodeLogCollector = nil
			}
			return self.isClaudeCodeConnected
		} catch {
			collector.append("Connection test threw error: \(error.localizedDescription)")
			collector.append("Disposing Claude Code provider resources after failure")
			await provider.dispose()
			collector.append("Claude Code provider disposed")
			self.isClaudeCodeConnected = false
			self.claudeCodeCLIStatus = Self.errorLooksLikeClaudeCodeBinaryMissing(error)
				? .binaryMissing(message: "Claude Code CLI isn't installed or isn't on PATH.")
				: .binaryPresent
			notifyClaudeCompatibleBackendRuntimeAvailabilityIfNeeded(previousStatus: previousStatus)
			UserDefaults.standard.set(self.isClaudeCodeConnected, forKey: "ClaudeCodeConnected")
			await self.updateAvailableModels()
			NotificationCenter.default.post(
				name: .claudeCodeConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			var friendlyMessage: String
			if let providerError = error as? AIProviderError {
				switch providerError {
				case .invalidConfiguration(let detail):
					friendlyMessage = detail
				case .apiError(let source):
					friendlyMessage = source?.localizedDescription ?? "Unknown API error"
				default:
					friendlyMessage = error.localizedDescription
				}
			} else {
				friendlyMessage = error.localizedDescription
			}
			self.claudeCodeError = friendlyMessage
			if self.claudeCodeError?.contains("not installed") == true {
				self.claudeCodeError = "Claude Code CLI is not installed. Please install it first."
			} else if self.claudeCodeError?.contains("not found") == true {
				self.claudeCodeError = "Claude Code CLI not found. Make sure it's installed and in your PATH."
			} else if self.claudeCodeError?.contains("permission denied") == true {
				self.claudeCodeError = "Permission denied. Ensure the 'claude' executable is installed and accessible."
			} else if self.claudeCodeError?.contains("unauthorized") == true ||
					self.claudeCodeError?.contains("authentication") == true {
				self.claudeCodeError = "Not authenticated. Please run 'claude login' in your terminal."
			} else if self.claudeCodeError?.contains("unknown option") == true &&
					self.claudeCodeError?.contains("--system-prompt") == true {
				self.claudeCodeError = "Your Claude Code CLI version is too old. Please update to the latest version to use this provider."
			}
			let finalMessage = self.claudeCodeError ?? friendlyMessage
			collector.append("User guidance: \(finalMessage)")
			throw error
		}
	}
	
	private func applyCodexConnectionState(
		connected: Bool,
		error: String?,
		phase: CodexConnectionPhase,
		updateModels: Bool,
		windowID: Int = 0
	) async {
		self.isCodexConnected = connected
		self.codexError = error
		self.codexConnectionPhase = phase
		UserDefaults.standard.set(connected, forKey: "CodexCLIConnected")
		if connected {
			startCodexModelsSubscriptionIfNeeded()
		} else {
			stopCodexModelsSubscription()
			self.availableCodexModels = []
		}
		if updateModels {
			await self.updateAvailableModels()
		}
		NotificationCenter.default.post(
			name: .codexConnectionChanged,
			object: nil,
			userInfo: ["windowID": windowID]
		)
	}

	private func applyCodexConnectionPhase(_ phase: CodexConnectionPhase, error: String? = nil) {
		self.codexConnectionPhase = phase
		self.codexError = error
	}

	private func codexFailurePhase(for message: String) -> CodexConnectionPhase {
		if CodexProviderHelpers.isCodexExecutableUnavailableMessage(message) {
			return .executableUnavailable(message: message)
		}
		if CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(message) {
			return .authRequired(message: message)
		}
		let lowered = message.lowercased()
		if lowered.contains("unauthorized") || lowered.contains("not authenticated") || lowered.contains("run 'codex login'") {
			return .authRequired(message: message)
		}
		return .failed(message: message)
	}

	private func preservesCodexServerRequestGuidance(_ message: String) -> Bool {
		let lowered = message.lowercased()
		return lowered.contains("account/chatgptauthtokens/refresh")
			|| lowered.contains("unsupported codex server request method:")
	}

	private func isCodexUserActionablePathIssue(_ message: String) -> Bool {
		if CodexProviderHelpers.isCodexExecutableUnavailableMessage(message) {
			return true
		}
		let lowered = message.lowercased()
		return lowered.contains("codex cli is not installed")
			|| lowered.contains("codex cli executable")
			|| lowered.contains("'codex' executable")
	}

	func resetCodexConnectionForSignOut(windowID: Int) async {
		self.codexLogCollector = nil
		await applyCodexConnectionState(
			connected: false,
			error: nil,
			phase: .idle,
			updateModels: true,
			windowID: windowID
		)
	}

	func startCodexManagedChatgptLogin(
		openURL: @MainActor @escaping (URL) -> Void
	) async throws -> Bool {
		await CLIEnvironmentCache.shared.invalidate()
		applyCodexConnectionPhase(.resolvingExecutable)

		let resolution = await CodexProviderHelpers.preflightCodexExecutable()
		guard resolution.status == .available else {
			await applyCodexConnectionState(
				connected: false,
				error: resolution.userMessage,
				phase: .executableUnavailable(message: resolution.userMessage),
				updateModels: true
			)
			throw AIProviderError.invalidConfiguration(detail: resolution.userMessage)
		}

		applyCodexConnectionPhase(.loggingIn)

		let result = await CodexManagedAuthRecoveryService.shared.startManagedChatgptLogin(openURL: openURL)
		switch result {
		case .authenticated:
			await applyCodexConnectionState(
				connected: true,
				error: nil,
				phase: .connected(resolvedExecutable: resolution.resolvedCommand),
				updateModels: true
			)
			return true
		case .failed(let message):
			await applyCodexConnectionState(
				connected: false,
				error: message,
				phase: codexFailurePhase(for: message),
				updateModels: true
			)
			throw AIProviderError.invalidConfiguration(detail: message)
		case .executableUnavailable(let message):
			await applyCodexConnectionState(
				connected: false,
				error: message,
				phase: .executableUnavailable(message: message),
				updateModels: true
			)
			throw AIProviderError.invalidConfiguration(detail: message)
		}
	}

	func testCodexConnection() async throws -> Bool {
		let collector = CLIProcessLogCollector()
		collector.append("Codex CLI connection test started")
		self.codexLogCollector = collector

		collector.append("Refreshing login-shell environment cache")
		await CLIEnvironmentCache.shared.invalidate()

		applyCodexConnectionPhase(.resolvingExecutable)
		collector.append("Resolving Codex CLI executable before authentication checks")
		let resolution = await CodexProviderHelpers.preflightCodexExecutable(logCollector: collector)
		guard resolution.status == .available else {
			collector.append("Codex executable unavailable before managed authentication refresh")
			await applyCodexConnectionState(
				connected: false,
				error: resolution.userMessage,
				phase: .executableUnavailable(message: resolution.userMessage),
				updateModels: true
			)
			collector.append("User guidance: \(resolution.userMessage)")
			throw AIProviderError.invalidConfiguration(detail: resolution.userMessage)
		}
		collector.append("Codex executable resolved at \(resolution.resolvedCommand)")

		applyCodexConnectionPhase(.refreshingAuth)
		collector.append("Checking Codex managed authentication state before health check")
		switch await CodexManagedAuthRecoveryService.shared.refreshManagedAccount() {
		case .recovered:
			collector.append("Codex managed authentication preflight succeeded")
		case .requiresUserLogin(let message):
			collector.append("Codex managed authentication preflight requires user login")
			await applyCodexConnectionState(
				connected: false,
				error: message,
				phase: .authRequired(message: message),
				updateModels: true
			)
			collector.append("User guidance: \(message)")
			throw AIProviderError.invalidConfiguration(detail: message)
		case .executableUnavailable(let message):
			collector.append("Codex executable unavailable before health check")
			await applyCodexConnectionState(
				connected: false,
				error: message,
				phase: .executableUnavailable(message: message),
				updateModels: true
			)
			collector.append("User guidance: \(message)")
			throw AIProviderError.invalidConfiguration(detail: message)
		}

		applyCodexConnectionPhase(.testingAppServer)

		// Use an owned non-agent Codex client so health-check failures cannot poison chat or polling.
		let provider = CodexCLIProvider(logCollector: collector)
		collector.append("Created Codex CLI provider for health check")

		do {
			let ok = try await provider.testConnection(timeout: 30)
			collector.append("Health check completed with status: \(ok ? "success" : "empty response")")
			collector.append("Disposing Codex CLI provider resources")
			await provider.dispose()
			collector.append("Codex CLI provider disposed")
			await applyCodexConnectionState(
				connected: ok,
				error: ok ? nil : "Codex CLI health check returned an empty response.",
				phase: ok ? .connected(resolvedExecutable: resolution.resolvedCommand) : .failed(message: "Codex CLI health check returned an empty response."),
				updateModels: true
			)
			if ok {
				collector.append("Codex CLI marked as connected")
				self.codexLogCollector = nil
			}
			return ok
		} catch {
			collector.append("Connection test threw error: \(error.localizedDescription)")
			collector.append("Disposing Codex CLI provider resources after failure")
			await provider.dispose()
			collector.append("Codex CLI provider disposed")
			let finalMessage = friendlyCodexMessage(for: error)
			await applyCodexConnectionState(
				connected: false,
				error: finalMessage,
				phase: codexFailurePhase(for: finalMessage),
				updateModels: true
			)
			collector.append("User guidance: \(finalMessage)")
			throw error
		}
	}
	
	private func friendlyCodexMessage(for error: Error) -> String {
		let message: String
		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidConfiguration(let detail):
				message = detail
			case .apiError(let source):
				message = source?.localizedDescription ?? "Unknown Codex CLI error"
			default:
				message = error.localizedDescription
			}
		} else {
			message = error.localizedDescription
		}

		if CodexProviderHelpers.isCodexExecutableUnavailableMessage(message)
			|| CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(message)
			|| preservesCodexServerRequestGuidance(message) {
			return message
		}

		let lowered = message.lowercased()
		if lowered.contains("not installed") || lowered.contains("no such file") || lowered.contains("command not found") {
			return "Codex CLI is not installed. Install it and ensure it's available on PATH."
		}
		if lowered.contains("permission denied") {
			return "Permission denied. Ensure the 'codex' executable is accessible."
		}
		if lowered.contains("unauthorized") || lowered.contains("not authenticated") {
			return "Codex CLI is not authenticated. Run 'codex login' in your terminal."
		}
		return message
	}

	func hasClaudeCodeTrace() -> Bool {
		return claudeCodeLogCollector?.isEmpty == false
	}
	
	func dumpClaudeCodeTrace() throws -> URL {
		guard let collector = claudeCodeLogCollector else {
			throw CLIProcessLogCollectorError.noEntries
		}
		collector.append("Exporting trace to Downloads folder")
		let exportDate = Date()
		let url = try collector.writeMarkdownToDownloads(
			baseFilename: "RepoPrompt-ClaudeCodeTrace",
			title: "Claude Code Connection Trace",
			timestamp: exportDate
		)
		collector.append("Trace exported to \(url.lastPathComponent)")
		return url
	}
	
	func hasCodexTrace() -> Bool {
		return codexLogCollector?.isEmpty == false
	}

	func shouldOfferCodexTraceDump() -> Bool {
		guard hasCodexTrace() else { return false }
		guard let codexError, !codexError.isEmpty else { return true }
		if isCodexUserActionablePathIssue(codexError) {
			return false
		}
		if CodexManagedAuthRecoveryClassifier.preservesAsUserFacingGuidance(codexError) {
			return false
		}
		let lowered = codexError.lowercased()
		if lowered.contains("not authenticated") || lowered.contains("run 'codex login'") {
			return false
		}
		return true
	}
	
	func dumpCodexTrace() throws -> URL {
		guard let collector = codexLogCollector else {
			throw CLIProcessLogCollectorError.noEntries
		}
		collector.append("Exporting trace to Downloads folder")
		let exportDate = Date()
		let url = try collector.writeMarkdownToDownloads(
			baseFilename: "RepoPrompt-CodexTrace",
			title: "Codex CLI Connection Trace",
			timestamp: exportDate
		)
		collector.append("Trace exported to \(url.lastPathComponent)")
		return url
	}

	func testGeminiConnection() async throws -> Bool {
		let collector = CLIProcessLogCollector()
		collector.append("Gemini CLI connection test started")
		self.geminiLogCollector = collector

		collector.append("Refreshing login-shell environment cache")
		await CLIEnvironmentCache.shared.invalidate()

		let provider = GeminiCLIProvider(logCollector: collector)
		collector.append("Created Gemini CLI provider for health check")

		do {
			let ok = try await provider.testConnection(timeout: 30)
			collector.append("Health check completed with status: \(ok ? "success" : "empty response")")
			collector.append("Disposing Gemini CLI provider resources")
			await provider.dispose()
			collector.append("Gemini CLI provider disposed")
			self.isGeminiConnected = ok
			self.geminiError = nil
			UserDefaults.standard.set(self.isGeminiConnected, forKey: "GeminiCLIConnected")
			await self.updateAvailableModels()
			NotificationCenter.default.post(
				name: .geminiConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			if ok {
				collector.append("Gemini CLI marked as connected")
				self.geminiLogCollector = nil
			}
			return self.isGeminiConnected
		} catch {
			collector.append("Connection test threw error: \(error.localizedDescription)")
			collector.append("Disposing Gemini CLI provider resources after failure")
			await provider.dispose()
			collector.append("Gemini CLI provider disposed")
			self.isGeminiConnected = false
			self.geminiError = friendlyGeminiMessage(for: error)
			if let lowered = self.geminiError?.lowercased() {
				if lowered.contains("not installed") || lowered.contains("no such file") || lowered.contains("command not found") {
					self.geminiError = "Gemini CLI is not installed. Install it and ensure it's available on PATH."
				} else if lowered.contains("permission denied") {
					self.geminiError = "Permission denied. Ensure the 'gemini' executable is accessible."
				} else if lowered.contains("unauthorized") || lowered.contains("not authenticated") {
					self.geminiError = "Gemini CLI is not authenticated. Run 'gemini login' in your terminal."
				}
			}
			UserDefaults.standard.set(self.isGeminiConnected, forKey: "GeminiCLIConnected")
			await self.updateAvailableModels()
			NotificationCenter.default.post(
				name: .geminiConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			let finalMessage = self.geminiError ?? error.localizedDescription
			collector.append("User guidance: \(finalMessage)")
			throw error
		}
	}

	private func friendlyGeminiMessage(for error: Error) -> String {
		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidConfiguration(let detail):
				return detail
			case .apiError(let source):
				return source?.localizedDescription ?? "Unknown Gemini CLI error"
			default:
				return error.localizedDescription
			}
		}
		return error.localizedDescription
	}

	func hasGeminiTrace() -> Bool {
		return geminiLogCollector?.isEmpty == false
	}

	func dumpGeminiTrace() throws -> URL {
		guard let collector = geminiLogCollector else {
			throw CLIProcessLogCollectorError.noEntries
		}
		collector.append("Exporting trace to Downloads folder")
		let exportDate = Date()
		let url = try collector.writeMarkdownToDownloads(
			baseFilename: "RepoPrompt-GeminiTrace",
			title: "Gemini CLI Connection Trace",
			timestamp: exportDate
		)
		collector.append("Trace exported to \(url.lastPathComponent)")
		return url
	}

	// MARK: - OpenCode CLI / ACP

	func testOpenCodeConnection() async throws -> Bool {
		let collector = CLIProcessLogCollector()
		collector.append("OpenCode CLI connection test started")
		self.openCodeLogCollector = collector

		collector.append("Refreshing login-shell environment cache")
		await CLIEnvironmentCache.shared.invalidate()
		collector.append("Starting OpenCode ACP model discovery preflight")

		do {
			let snapshot = try await OpenCodeACPModelPollingService.shared.discoverOnce(workspacePath: nil)
			guard let snapshot else {
				throw AIProviderError.invalidConfiguration(detail: "OpenCode ACP preflight completed but no model metadata was discovered.")
			}
			collector.append("Discovered \(snapshot.models.options.count) OpenCode model option(s)")
			self.availableOpenCodeModelOptions = snapshot.models.options
			self.isOpenCodeConnected = true
			self.openCodeError = nil
			UserDefaults.standard.set(true, forKey: "OpenCodeCLIConnected")
			startOpenCodeModelsSubscriptionIfNeeded(workspacePath: nil)
			await self.updateAvailableModels()
			collector.append("OpenCode CLI marked as connected")
			self.openCodeLogCollector = nil
			NotificationCenter.default.post(
				name: .openCodeConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			return true
		} catch {
			collector.append("Connection test threw error: \(error.localizedDescription)")
			self.isOpenCodeConnected = false
			self.openCodeError = friendlyOpenCodeMessage(for: error)
			UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
			stopOpenCodeModelsSubscription(clearModels: true)
			await self.updateAvailableModels()
			let finalMessage = self.openCodeError ?? error.localizedDescription
			collector.append("User guidance: \(finalMessage)")
			NotificationCenter.default.post(
				name: .openCodeConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			throw error
		}
	}

	func disconnectOpenCode() {
		isOpenCodeConnected = false
		openCodeError = nil
		UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
		stopOpenCodeModelsSubscription(clearModels: true)
		Task { await updateAvailableModels() }
		NotificationCenter.default.post(
			name: .openCodeConnectionChanged,
			object: nil,
			userInfo: ["windowID": 0]
		)
	}

	private func friendlyOpenCodeMessage(for error: Error) -> String {
		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidConfiguration(let detail):
				return detail
			case .apiError(let source):
				return source?.localizedDescription ?? "Unknown OpenCode CLI error"
			default:
				return error.localizedDescription
			}
		}
		let message = error.localizedDescription
		let lowered = message.lowercased()
		if lowered.contains("not installed") || lowered.contains("no such file") || lowered.contains("command not found") {
			return "OpenCode CLI is not installed. Install it and ensure `opencode` is available on PATH."
		}
		if lowered.contains("permission denied") {
			return "Permission denied. Ensure the `opencode` executable is accessible."
		}
		if lowered.contains("unauthorized") || lowered.contains("not authenticated") || lowered.contains("login") {
			return "OpenCode CLI is not authenticated. Run `opencode auth login` in your terminal."
		}
		if lowered.contains("does not advertise acp") || lowered.contains("acp support") {
			return "Installed OpenCode CLI does not support ACP. Update OpenCode and try again."
		}
		return message
	}

	func hasOpenCodeTrace() -> Bool {
		openCodeLogCollector?.isEmpty == false
	}

	func dumpOpenCodeTrace() throws -> URL {
		guard let collector = openCodeLogCollector else {
			throw CLIProcessLogCollectorError.noEntries
		}
		collector.append("Exporting trace to Downloads folder")
		let exportDate = Date()
		let url = try collector.writeMarkdownToDownloads(
			baseFilename: "RepoPrompt-OpenCodeTrace",
			title: "OpenCode CLI Connection Trace",
			timestamp: exportDate
		)
		collector.append("Trace exported to \(url.lastPathComponent)")
		return url
	}

	private func startOpenCodeModelsSubscriptionIfNeeded(workspacePath: String?) {
		guard openCodeModelsTask == nil else { return }
		openCodeModelsTask = Task { [weak self, workspacePath] in
			let stream = await OpenCodeACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
			for await snapshot in stream {
				guard !Task.isCancelled else { return }
				await MainActor.run { [weak self] in
					self?.availableOpenCodeModelOptions = snapshot.models.options
				}
				await self?.updateAvailableModels()
			}
		}
	}

	private func stopOpenCodeModelsSubscription(clearModels: Bool = false) {
		openCodeModelsTask?.cancel()
		openCodeModelsTask = nil
		if clearModels {
			availableOpenCodeModelOptions = []
		}
	}

	// MARK: - Cursor CLI / ACP

	func testCursorConnection() async throws -> Bool {
		let collector = CLIProcessLogCollector()
		collector.append("Cursor CLI connection test started")
		collector.append("Preferred Cursor model fallback: \(AgentModel.cursorAuto.rawValue)")
		self.cursorLogCollector = collector

		collector.append("Refreshing login-shell environment cache")
		await CLIEnvironmentCache.shared.invalidate()
		collector.append("Starting Cursor ACP model discovery preflight")

		do {
			let snapshot = try await CursorACPModelPollingService.shared.discoverOnce(workspacePath: nil)
			let cursorOptions = AgentModelCatalog.options(
				for: .cursor,
				availability: AgentModelCatalog.AvailabilityContext(cursorAvailable: true, zaiConfigured: false)
			)
			if let snapshot {
				collector.append("Discovered \(snapshot.models.options.count) Cursor model option(s)")
				self.availableCursorModelOptions = cursorOptions
			} else {
				collector.append("Cursor ACP preflight completed without dynamic model metadata; using Auto fallback")
				self.availableCursorModelOptions = cursorOptions
			}
			self.isCursorConnected = true
			self.cursorError = nil
			UserDefaults.standard.set(true, forKey: "CursorCLIConnected")
			startCursorModelsSubscriptionIfNeeded(workspacePath: nil)
			await self.updateAvailableModels()
			collector.append("Cursor CLI marked as connected")
			self.cursorLogCollector = nil
			NotificationCenter.default.post(
				name: .cursorConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			return true
		} catch {
			collector.append("Connection test threw error: \(error.localizedDescription)")
			self.isCursorConnected = false
			self.cursorError = friendlyCursorMessage(for: error)
			UserDefaults.standard.set(false, forKey: "CursorCLIConnected")
			stopCursorModelsSubscription(clearModels: true)
			await self.updateAvailableModels()
			let finalMessage = self.cursorError ?? error.localizedDescription
			collector.append("User guidance: \(finalMessage)")
			NotificationCenter.default.post(
				name: .cursorConnectionChanged,
				object: nil,
				userInfo: ["windowID": 0]
			)
			throw error
		}
	}

	func disconnectCursor() {
		isCursorConnected = false
		cursorError = nil
		UserDefaults.standard.set(false, forKey: "CursorCLIConnected")
		stopCursorModelsSubscription(clearModels: true)
		Task {
			await updateAvailableModels()
			resetPreferredModelIfNeeded(for: .cursor)
		}
		NotificationCenter.default.post(
			name: .cursorConnectionChanged,
			object: nil,
			userInfo: ["windowID": 0]
		)
	}

	private func friendlyCursorMessage(for error: Error) -> String {
		if let providerError = error as? AIProviderError {
			switch providerError {
			case .invalidConfiguration(let detail):
				return detail
			case .apiError(let source):
				return source?.localizedDescription ?? "Unknown Cursor CLI error"
			default:
				return error.localizedDescription
			}
		}
		let message = error.localizedDescription
		let lowered = message.lowercased()
		if lowered.contains("not installed") || lowered.contains("no such file") || lowered.contains("command not found") || lowered.contains("not found") {
			return "Cursor CLI ACP server was not found. Install Cursor CLI and ensure `cursor-agent acp` or `cursor agent acp` is available on PATH."
		}
		if lowered.contains("permission denied") {
			return "Permission denied. Ensure the `cursor-agent` executable is accessible."
		}
		if lowered.contains("unauthorized") || lowered.contains("not authenticated") || lowered.contains("login") {
			return "Cursor CLI is not authenticated. Set `CURSOR_API_KEY`/`CURSOR_AUTH_TOKEN` or complete Cursor login."
		}
		if lowered.contains("does not advertise acp") || lowered.contains("acp support") {
			return "Installed Cursor CLI does not support ACP mode. Update Cursor CLI and ensure `cursor-agent acp --help` works."
		}
		return message
	}

	func hasCursorTrace() -> Bool {
		cursorLogCollector?.isEmpty == false
	}

	func dumpCursorTrace() throws -> URL {
		guard let collector = cursorLogCollector else {
			throw CLIProcessLogCollectorError.noEntries
		}
		collector.append("Exporting trace to Downloads folder")
		let exportDate = Date()
		let url = try collector.writeMarkdownToDownloads(
			baseFilename: "RepoPrompt-CursorTrace",
			title: "Cursor CLI Connection Trace",
			timestamp: exportDate
		)
		collector.append("Trace exported to \(url.lastPathComponent)")
		return url
	}

	private func startCursorModelsSubscriptionIfNeeded(workspacePath: String?) {
		guard cursorModelsTask == nil else { return }
		cursorModelsTask = Task { [weak self, workspacePath] in
			let stream = await CursorACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
			for await _ in stream {
				guard !Task.isCancelled else { return }
				await MainActor.run { [weak self] in
					self?.availableCursorModelOptions = AgentModelCatalog.options(
						for: .cursor,
						availability: AgentModelCatalog.AvailabilityContext(cursorAvailable: true, zaiConfigured: false)
					)
				}
				await self?.updateAvailableModels()
			}
		}
	}

	private func stopCursorModelsSubscription(clearModels: Bool = false) {
		cursorModelsTask?.cancel()
		cursorModelsTask = nil
		if clearModels {
			availableCursorModelOptions = []
		}
	}

	func isCustomModelEnabled(_ modelName: String) -> Bool {
		return customEnabledModelSet.contains(modelName)
	}
	
	// MARK: - Stand-alone Custom-Provider settings
	func saveCustomProviderMaxTokens() async throws {
		// Accept blank → nil  (model default)
		let trimmed = customProviderMaxTokensString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let config = try? CustomProviderConfiguration.load() else {
			throw AIProviderError.providerNotConfigured
		}
		var newConfig = config
		if let intVal = Int(trimmed), intVal > 0 {
			newConfig.maxTokens = intVal
		} else {
			newConfig.maxTokens = nil         // 0 or invalid ⇒ use provider default
		}
		try CustomProviderConfiguration.save(newConfig)
		// No need to hit the network – just update cached string so UI stays in sync
		await MainActor.run {
			self.customProviderMaxTokensString = trimmed.isEmpty ? "" : trimmed
		}
	}
	
	func toggleCustomModel(_ modelName: String) {
		do {
			var config = try CustomProviderConfiguration.load()
			let isEnabled = !config.enabledModels.contains(modelName)
			config.updateModelSettings(model: modelName, isEnabled: isEnabled)
			try CustomProviderConfiguration.save(config)

			// Keep the in-memory cache in sync
			if isEnabled {
				customEnabledModelSet.insert(modelName)
			} else {
				customEnabledModelSet.remove(modelName)
			}
			
			Task {
				await updateAvailableModels()
			}
		} catch {
			print("Error toggling custom model: \(error)")
		}
	}
	
	func fetchOpenRouterModels() async {
		guard !openRouterApiKey.isEmpty else {
			return
		}
		
		await MainActor.run {
			isFetchingOpenRouterModels = true
			lastErrorMessage = nil
		}
		
		do {
			let provider = CustomOpenAIProvider(
				baseURL: "https://openrouter.ai/api/v1",
				apiKey: openRouterApiKey,
				defaultModel: "openai/gpt-4o-mini",
				defaultTemperature: 0.7,
				customHeaders: [
					"HTTP-Referer": "https://repoprompt.com/",
					"X-Title": "Repo Prompt"
				]
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run {
				self.fetchedOpenRouterModels = Array(Set(models)).sorted()
				self.isFetchingOpenRouterModels = false
			}
		} catch {
			await MainActor.run {
				self.lastErrorMessage = "Failed to fetch OpenRouter models: \(error.localizedDescription)"
				self.fetchedOpenRouterModels = []
				self.isFetchingOpenRouterModels = false
			}
		}
	}
	
	// MARK: - Remote-model fetch helpers
	
	// SEARCH-HELPER: OpenAI Base URL, Custom Base URL, Normalization
	private func normalizedOpenAIBaseURL(_ raw: String) -> String {
		let (base, _) = normalizedOpenAIBaseURLAndVersion(raw)
		return base
	}

	private func normalizedOpenAIBaseURLAndVersion(_ raw: String?) -> (String, String?) {
		let (u, v) = OpenAIURLHelper.splitBaseURLAndVersion(raw)
		return (u?.absoluteString ?? "", v)
	}
	
	private func updateOpenAIModels() async {
		guard isOpenAIKeyValid else { return }
		do {
			// Compute base + version from current field (fallback to stored version if not present in field)
			let (baseFromField, versionFromField) = normalizedOpenAIBaseURLAndVersion(openAIBaseURL)
			let base = baseFromField.isEmpty ? "https://api.openai.com" : baseFromField
			let version = versionFromField ?? (UserDefaults.standard.string(forKey: "customOpenAIVersionOverride") ?? "v1")

			let provider = CustomOpenAIProvider(
				baseURL: base,
				apiKey: openAIApiKey,
				defaultModel: "gpt-3.5-turbo",
				defaultTemperature: 0.7,
				apiVersion: version
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run { availableOpenAIModels = models }
		} catch {
			await MainActor.run { availableOpenAIModels = [] }
		}
		await updateAvailableModels()
	}

	private func updateDeepSeekModels() async {
		guard isDeepSeekKeyValid else { return }
		do {
			let provider = CustomOpenAIProvider(
				baseURL: "https://api.deepseek.com/v1",
				apiKey: deepSeekApiKey,
				defaultModel: "deepseek-chat",
				defaultTemperature: 0.7
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run { availableDeepSeekModels = models }
		} catch {
			await MainActor.run { availableDeepSeekModels = [] }
		}
		await updateAvailableModels()
	}

	private func updateFireworksModels() async {
		guard isFireworksKeyValid else { return }
		do {
			let provider = CustomOpenAIProvider(
				baseURL: "https://api.fireworks.ai/inference/v1",
				apiKey: fireworksApiKey,
				defaultModel: "accounts/fireworks/models/llama-v4-maverick",
				defaultTemperature: 0.7
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run { availableFireworksModels = models }
		} catch {
			await MainActor.run { availableFireworksModels = [] }
		}
		await updateAvailableModels()
	}

	/// Starts a subscription to the centralized Codex model polling service.
	/// Replaces the previous ephemeral-client one-shot refresh.
	private func startCodexModelsSubscriptionIfNeeded() {
		guard codexModelsTask == nil else { return }
		codexModelsTask = Task { [weak self] in
			guard let self else { return }

			// subscribe() starts the polling loop if idle and immediately yields the latest
			// snapshot (if available). The polling loop refreshes immediately on first tick,
			// so no explicit refreshNow() is needed here.
			let stream = await CodexModelPollingService.shared.subscribe()
			for await snapshot in stream {
				guard !Task.isCancelled else { return }
				await MainActor.run {
					self.availableCodexModels = snapshot.models
				}
				await self.updateAvailableModels()
			}
		}
	}

	private func stopCodexModelsSubscription() {
		codexModelsTask?.cancel()
		codexModelsTask = nil
	}

	private func updateGrokModels() async {
		guard isGrokKeyValid else { return }
		do {
			// GrokProvider inherits from OpenAIProvider, so CustomOpenAIProvider can be used for model listing
			// if Grok's /models endpoint is OpenAI-compatible.
			let provider = CustomOpenAIProvider(
				baseURL: "https://api.x.ai/v1", // Grok API base URL for models
				apiKey: grokApiKey,
				defaultModel: "grok-3-mini-beta", // A known Grok model
				defaultTemperature: 0.7
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run { availableGrokModels = models }
		} catch {
			await MainActor.run { availableGrokModels = [] }
			print("Error fetching Grok models: \(error.asFriendlyString())")
		}
		await updateAvailableModels()
	}
	
	private func updateGroqModels() async {
		guard isGroqKeyValid else { return }
		do {
			// GroqProvider inherits from OpenAIProvider, so CustomOpenAIProvider can be used for model listing
			// if Groq's /models endpoint is OpenAI-compatible.
			let provider = CustomOpenAIProvider(
				baseURL: "https://api.groq.com/openai/v1", // Groq API base URL for models
				apiKey: groqApiKey,
				defaultModel: "moonshotai/kimi-k2-instruct", // Default Groq model
				defaultTemperature: 0.7
			)
			let models = try await provider.getAvailableModels()
			await MainActor.run { availableGroqModels = models }
		} catch {
			await MainActor.run { availableGroqModels = [] }
			print("Error fetching Groq models: \(error.asFriendlyString())")
		}
		await updateAvailableModels()
	}
}

// MARK: - Provider Flags Extension

extension APISettingsViewModel {
	/// Helper struct to expose provider status for the recommendation engine.
	struct ProviderFlags {
		let hasOpenAIKey: Bool
		let openAIValid: Bool
		let claudeCodeConnected: Bool
		let codexConnected: Bool
		let geminiCLIConnected: Bool
		let cursorConnected: Bool
	}
	
	/// Get a snapshot of all provider flags for use by other services.
	var providerFlags: ProviderFlags {
		ProviderFlags(
			hasOpenAIKey: !openAIApiKey.isEmpty,
			openAIValid: isOpenAIKeyValid,
			claudeCodeConnected: isClaudeCodeConnected,
			codexConnected: isCodexConnected,
			geminiCLIConnected: isGeminiConnected,
			cursorConnected: isCursorConnected
		)
	}
}
