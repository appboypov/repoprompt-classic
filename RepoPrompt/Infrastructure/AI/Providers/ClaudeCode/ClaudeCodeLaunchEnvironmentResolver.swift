import Foundation

enum ClaudeCodeGLMIntegration {
	static let configuredDefaultsKey = "ClaudeCodeGLMZAIConfigured"
	static let defaultModelRawValue = "glm-5-turbo"
	static let haikuEquivalentModelRawValue = "glm-4.7"
	static let opusEquivalentModelRawValue = "glm-5.1"
	static let legacyOpusEquivalentModelRawValue = "glm-5"
	static let defaultRequestedModelRawValue = AgentModel.claudeSonnet.rawValue
	static let haikuRequestedModelRawValue = AgentModel.claudeHaiku.rawValue
	static let opusRequestedModelRawValue = AgentModel.claudeOpus.rawValue
	static let supportedModelRawValues: [String] = [
		haikuEquivalentModelRawValue,
		defaultModelRawValue,
		opusEquivalentModelRawValue
	]
	static let legacyModelRawValues: [String] = [
		AgentModel.glm46.rawValue,
		legacyOpusEquivalentModelRawValue
	]

	static func isGLMModel(_ rawModel: String?) -> Bool {
		isGLMModel(rawModel, config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI))
	}

	static func isGLMModel(
		_ rawModel: String?,
		config: ClaudeCodeCompatibleBackendConfig
	) -> Bool {
		guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else { return false }
		if slot(forBackendModelID: normalized, in: slotMapping(from: config)) != nil {
			return true
		}
		return supportedModelRawValues.contains(normalized) || legacyModelRawValues.contains(normalized)
	}

	static func isConfigured(defaults: UserDefaults = .standard) -> Bool {
		ClaudeCodeCompatibleBackendIntegration.isConfigured(.glmZAI, defaults: defaults)
	}

	@discardableResult
	static func setConfigured(_ isConfigured: Bool, defaults: UserDefaults = .standard) -> Bool {
		ClaudeCodeCompatibleBackendIntegration.setConfigured(isConfigured, for: .glmZAI, defaults: defaults)
	}

	static func environment(apiKey: String) -> [String: String] {
		ClaudeCodeCompatibleBackendIntegration.environment(
			config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI),
			apiKey: apiKey
		)
	}

	static func normalizedRequestedModel(_ rawModel: String?) -> String? {
		guard let rawModel else { return nil }
		let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != AgentModel.defaultModel.rawValue else { return nil }
		return trimmed
	}

	static func normalizedGLMModel(_ rawModel: String?) -> String? {
		normalizedGLMModel(rawModel, config: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI))
	}

	static func displayName(forRequestedModelRaw rawModel: String?) -> String? {
		let mapping = currentSlotMapping()
		switch normalizedGLMModel(rawModel) {
		case haikuRequestedModelRawValue:
			return displayName(forBackendModelID: mapping.haiku)
		case defaultRequestedModelRawValue:
			return displayName(forBackendModelID: mapping.sonnet)
		case opusRequestedModelRawValue:
			return displayName(forBackendModelID: mapping.opus)
		default:
			return nil
		}
	}

	static func description(forRequestedModelRaw rawModel: String?) -> String? {
		let mapping = currentSlotMapping()
		switch normalizedGLMModel(rawModel) {
		case haikuRequestedModelRawValue:
			return "Routes Claude Code's Haiku model slot to \(mapping.haiku) via Z.ai's Anthropic-compatible backend"
		case defaultRequestedModelRawValue:
			return "Routes Claude Code's Sonnet model slot to \(mapping.sonnet) via Z.ai's Anthropic-compatible backend"
		case opusRequestedModelRawValue:
			return "Routes Claude Code's Opus model slot to \(mapping.opus) via Z.ai's Anthropic-compatible backend"
		default:
			return nil
		}
	}

	static func normalizedGLMModel(
		_ rawModel: String?,
		config: ClaudeCodeCompatibleBackendConfig
	) -> String? {
		guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
			return defaultRequestedModelRawValue
		}

		let mapping = slotMapping(from: config)
		switch normalized {
		case AgentModel.claudeHaiku.rawValue.lowercased():
			return haikuRequestedModelRawValue
		case AgentModel.claudeSonnet.rawValue.lowercased():
			return defaultRequestedModelRawValue
		case AgentModel.claudeOpus.rawValue.lowercased():
			return opusRequestedModelRawValue
		default:
			break
		}

		if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
			return configuredSlot
		}

		switch normalized {
		case haikuEquivalentModelRawValue, AgentModel.glm46.rawValue:
			return haikuRequestedModelRawValue
		case defaultModelRawValue:
			return defaultRequestedModelRawValue
		case opusEquivalentModelRawValue, legacyOpusEquivalentModelRawValue:
			return opusRequestedModelRawValue
		default:
			return nil
		}
	}

	static func normalizedSlotModel(
		_ rawModel: String?,
		config: ClaudeCodeCompatibleBackendConfig,
		acceptGLMLegacyAliases: Bool
	) -> String? {
		guard let normalized = normalizedRequestedModel(rawModel)?.lowercased() else {
			return defaultRequestedModelRawValue
		}

		let mapping = slotMapping(from: config)
		switch normalized {
		case AgentModel.claudeHaiku.rawValue.lowercased():
			return haikuRequestedModelRawValue
		case AgentModel.claudeSonnet.rawValue.lowercased():
			return defaultRequestedModelRawValue
		case AgentModel.claudeOpus.rawValue.lowercased():
			return opusRequestedModelRawValue
		default:
			break
		}

		if let configuredSlot = slot(forBackendModelID: normalized, in: mapping) {
			return configuredSlot
		}

		guard acceptGLMLegacyAliases else { return nil }
		return normalizedGLMModel(normalized, config: config)
	}

	private static func currentSlotMapping() -> ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping {
		slotMapping(from: ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI))
	}

	private static func slotMapping(
		from config: ClaudeCodeCompatibleBackendConfig
	) -> ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping {
		if case .claudeSlotMapping(let mapping) = config.modelBehavior {
			return mapping.normalized
		}
		if case .claudeSlotMapping(let mapping) = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior {
			return mapping.normalized
		}
		return ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
			haiku: haikuEquivalentModelRawValue,
			sonnet: defaultModelRawValue,
			opus: opusEquivalentModelRawValue
		)
	}

	private static func slot(
		forBackendModelID modelID: String,
		in mapping: ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping
	) -> String? {
		let normalizedMapping = mapping.normalized
		if modelID == normalizedMapping.haiku.lowercased() {
			return haikuRequestedModelRawValue
		}
		if modelID == normalizedMapping.sonnet.lowercased() {
			return defaultRequestedModelRawValue
		}
		if modelID == normalizedMapping.opus.lowercased() {
			return opusRequestedModelRawValue
		}
		return nil
	}

	private static func displayName(forBackendModelID modelID: String) -> String {
		if let model = AgentModel(rawValue: modelID) {
			return model.displayName
		}
		return modelID
	}
}

extension Notification.Name {
	static let claudeCodeGLMAvailabilityChanged = Notification.Name("claudeCodeGLMAvailabilityChanged")
}

struct ClaudeCodeLaunchEnvironment: Sendable {
	enum Backend: Sendable, Equatable {
		case defaultClaude
		case compatible(ClaudeCodeCompatibleBackendID)
	}

	let effectiveModel: String?
	let environmentOverrides: [String: String]
	let removedEnvironmentKeys: Set<String>
	let backend: Backend
	let suppressesEffortSettings: Bool

	init(
		effectiveModel: String?,
		environmentOverrides: [String: String],
		removedEnvironmentKeys: Set<String> = [],
		backend: Backend,
		suppressesEffortSettings: Bool = false
	) {
		self.effectiveModel = effectiveModel
		self.environmentOverrides = environmentOverrides
		self.removedEnvironmentKeys = removedEnvironmentKeys
		self.backend = backend
		self.suppressesEffortSettings = suppressesEffortSettings
	}
}

protocol ClaudeCodeLaunchEnvironmentResolving: Sendable {
	func resolve(
		variant: ClaudeCodeRuntimeVariant,
		requestedModel: String?
	) async throws -> ClaudeCodeLaunchEnvironment
}

struct ClaudeCodeLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
	typealias ZAIKeyProvider = @Sendable () async throws -> String?
	typealias BackendSecretProvider = @Sendable (_ backendID: ClaudeCodeCompatibleBackendID) async throws -> String?

	private let zaiKeyProvider: ZAIKeyProvider
	private let backendSecretProvider: BackendSecretProvider
	private let backendStore: ClaudeCodeCompatibleBackendStore

	init(
		keyManager: KeyManager = KeyManager(),
		backendStore: ClaudeCodeCompatibleBackendStore = .shared
	) {
		let store = backendStore
		self.zaiKeyProvider = {
			try await keyManager.getAPIKey(for: .zAI)
		}
		self.backendSecretProvider = { id in
			try await store.secret(for: id)
		}
		self.backendStore = store
	}

	init(
		zaiKeyProvider: @escaping ZAIKeyProvider,
		backendSecretProvider: BackendSecretProvider? = nil,
		backendStore: ClaudeCodeCompatibleBackendStore = .shared
	) {
		let store = backendStore
		self.zaiKeyProvider = zaiKeyProvider
		self.backendSecretProvider = backendSecretProvider ?? { id in
			try await store.secret(for: id)
		}
		self.backendStore = store
	}

	func resolve(
		variant: ClaudeCodeRuntimeVariant,
		requestedModel: String?
	) async throws -> ClaudeCodeLaunchEnvironment {
		switch variant {
		case .standard:
			let normalizedModel = ClaudeCodeGLMIntegration.normalizedRequestedModel(requestedModel)
			let glmConfig = backendStore.config(for: .glmZAI)
			if ClaudeCodeGLMIntegration.isGLMModel(normalizedModel, config: glmConfig) {
				throw AIProviderError.invalidConfiguration(detail: "GLM models require the Claude Code GLM agent.")
			}
			if isKnownNoModelCompatibleRaw(normalizedModel) {
				throw AIProviderError.invalidConfiguration(detail: "Compatible backend models require their matching Claude-compatible agent.")
			}
			return ClaudeCodeLaunchEnvironment(
				effectiveModel: normalizedModel,
				environmentOverrides: [:],
				backend: .defaultClaude
			)
		case .glm, .kimi, .customCompatible:
			guard let backendID = variant.compatibleBackendID else {
				throw AIProviderError.invalidConfiguration(detail: "Unsupported Claude Code runtime variant.")
			}
			return try await resolveCompatibleBackend(backendID, variant: variant, requestedModel: requestedModel)
		}
	}

	private func resolveCompatibleBackend(
		_ backendID: ClaudeCodeCompatibleBackendID,
		variant: ClaudeCodeRuntimeVariant,
		requestedModel: String?
	) async throws -> ClaudeCodeLaunchEnvironment {
		let config = backendStore.config(for: backendID).normalized
		guard config.isEnabled, config.isValid else {
			throw AIProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) has an invalid backend configuration.")
		}

		let effectiveModel: String?
		switch config.modelBehavior {
		case .noModel:
			guard isAllowedNoModelSelection(requestedModel, backendID: backendID) else {
				throw AIProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
			}
			effectiveModel = nil
		case .claudeSlotMapping:
			guard let slot = ClaudeCodeGLMIntegration.normalizedSlotModel(
				requestedModel,
				config: config,
				acceptGLMLegacyAliases: backendID == .glmZAI
			) else {
				throw AIProviderError.invalidConfiguration(detail: "Unsupported \(config.normalizedDisplayName) model selection.")
			}
			effectiveModel = slot
		}

		let apiKey: String?
		if backendID == .glmZAI {
			apiKey = try await zaiKeyProvider()
		} else {
			apiKey = try await backendSecretProvider(backendID)
		}
		guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
			!apiKey.isEmpty else {
			throw AIProviderError.invalidConfiguration(detail: "\(config.normalizedDisplayName) requires a configured API key.")
		}

		return ClaudeCodeLaunchEnvironment(
			effectiveModel: effectiveModel,
			environmentOverrides: ClaudeCodeCompatibleBackendIntegration.environment(config: config, apiKey: apiKey),
			removedEnvironmentKeys: ClaudeCodeCompatibleBackendIntegration.removedEnvironmentKeys(config: config),
			backend: .compatible(backendID),
			suppressesEffortSettings: config.modelBehavior == .noModel
		)
	}

	private func isAllowedNoModelSelection(
		_ rawModel: String?,
		backendID: ClaudeCodeCompatibleBackendID
	) -> Bool {
		guard let normalized = ClaudeCodeGLMIntegration.normalizedRequestedModel(rawModel)?.lowercased() else {
			return true
		}
		return normalized == noModelRawValue(for: backendID)
	}

	private func isKnownNoModelCompatibleRaw(_ rawModel: String?) -> Bool {
		guard let normalized = ClaudeCodeGLMIntegration.normalizedRequestedModel(rawModel)?.lowercased() else {
			return false
		}
		return normalized == noModelRawValue(for: .kimi) || normalized == noModelRawValue(for: .custom)
	}

	private func noModelRawValue(for backendID: ClaudeCodeCompatibleBackendID) -> String {
		switch backendID {
		case .glmZAI:
			return AgentModel.claudeSonnet.rawValue
		case .kimi:
			return AgentModel.kimiCode.rawValue.lowercased()
		case .custom:
			return AgentModel.customClaudeCompatible.rawValue.lowercased()
		}
	}
}
