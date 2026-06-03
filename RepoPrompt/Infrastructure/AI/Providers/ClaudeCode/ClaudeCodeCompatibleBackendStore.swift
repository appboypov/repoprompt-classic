import Foundation

final class ClaudeCodeCompatibleBackendStore: @unchecked Sendable {
	static let shared = ClaudeCodeCompatibleBackendStore()

	static let configsDefaultsKey = "ClaudeCodeCompatibleBackendConfigs"
	private static let configuredDefaultsKeyPrefix = "ClaudeCodeCompatibleBackendConfigured."

	private let defaults: UserDefaults
	private let secureService: SecureKeysService
	// SEARCH-HELPER: Concurrency, Locking, DataRace
	// Serializes UserDefaults-backed config and `configured` mirror reads/writes so
	// catalog (sync), launch resolution (async), and settings UI (MainActor) can touch
	// this shared store safely without a larger actor refactor.
	private let lock = NSLock()

	init(
		defaults: UserDefaults = .standard,
		secureService: SecureKeysService = SecureKeysService()
	) {
		self.defaults = defaults
		self.secureService = secureService
	}

	func config(for id: ClaudeCodeCompatibleBackendID) -> ClaudeCodeCompatibleBackendConfig {
		lock.lock()
		defer { lock.unlock() }
		return loadConfigsLocked()[id.rawValue] ?? id.defaultPreset
	}

	func saveConfig(_ config: ClaudeCodeCompatibleBackendConfig) {
		lock.lock()
		defer { lock.unlock() }
		var configs = loadConfigsLocked()
		var normalized = config.normalized
		normalized.updatedAt = Date()
		configs[normalized.id.rawValue] = normalized
		saveConfigsLocked(configs)
	}

	func resetConfig(for id: ClaudeCodeCompatibleBackendID) {
		lock.lock()
		defer { lock.unlock() }
		var configs = loadConfigsLocked()
		configs.removeValue(forKey: id.rawValue)
		saveConfigsLocked(configs)
	}

	func isConfigured(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return isConfiguredLocked(id)
	}

	@discardableResult
	func setConfigured(_ configured: Bool, for id: ClaudeCodeCompatibleBackendID) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let previousValue = isConfiguredLocked(id)
		defaults.set(configured, forKey: configuredDefaultsKey(for: id))
		if id == .glmZAI {
			defaults.set(configured, forKey: ClaudeCodeGLMIntegration.configuredDefaultsKey)
		}
		return previousValue != configured
	}

	func hasSecret(for id: ClaudeCodeCompatibleBackendID) async -> Bool {
		do {
			guard let rawSecret = try await secret(for: id) else { return false }
			let trimmedSecret = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
			return !trimmedSecret.isEmpty
		} catch {
			return false
		}
	}

	func secret(for id: ClaudeCodeCompatibleBackendID) async throws -> String? {
		try await secureService.getAPIKey(for: id.secretIdentifier)
	}

	func saveSecret(_ secret: String, for id: ClaudeCodeCompatibleBackendID) async throws {
		let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			try await deleteSecret(for: id)
			return
		}
		try secureService.saveAPIKey(trimmed, for: id.secretIdentifier)
		_ = setConfigured(true, for: id)
	}

	func deleteSecret(for id: ClaudeCodeCompatibleBackendID) async throws {
		try secureService.deleteAPIKey(for: id.secretIdentifier)
		_ = setConfigured(false, for: id)
	}

	func configuredDefaultsKey(for id: ClaudeCodeCompatibleBackendID) -> String {
		Self.configuredDefaultsKeyPrefix + id.rawValue
	}

	/// Callers must hold `lock` for the entire read/legacy-migration sequence.
	private func isConfiguredLocked(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
		let key = configuredDefaultsKey(for: id)
		if let configured = defaults.object(forKey: key) as? Bool {
			return configured
		}

		guard id == .glmZAI,
			let legacyConfigured = defaults.object(forKey: ClaudeCodeGLMIntegration.configuredDefaultsKey) as? Bool else {
			return false
		}
		defaults.set(legacyConfigured, forKey: key)
		return legacyConfigured
	}

	/// Callers must hold `lock`. Uses a local decoder so the store can stay a
	/// lightweight `@unchecked Sendable` shared instance without sharing a
	/// `JSONDecoder` across threads.
	private func loadConfigsLocked() -> [String: ClaudeCodeCompatibleBackendConfig] {
		guard let data = defaults.data(forKey: Self.configsDefaultsKey) else { return [:] }
		let decoder = JSONDecoder()
		return (try? decoder.decode([String: ClaudeCodeCompatibleBackendConfig].self, from: data)) ?? [:]
	}

	/// Callers must hold `lock`. Uses a local encoder for the same reason as
	/// `loadConfigsLocked`.
	private func saveConfigsLocked(_ configs: [String: ClaudeCodeCompatibleBackendConfig]) {
		let encoder = JSONEncoder()
		guard let data = try? encoder.encode(configs) else { return }
		defaults.set(data, forKey: Self.configsDefaultsKey)
	}
}

enum ClaudeCodeCompatibleBackendIntegration {
	private static let glmTimeoutMilliseconds = "3000000"

	static func isConfigured(
		_ id: ClaudeCodeCompatibleBackendID,
		defaults: UserDefaults = .standard
	) -> Bool {
		ClaudeCodeCompatibleBackendStore(defaults: defaults).isConfigured(id)
	}

	@discardableResult
	static func setConfigured(
		_ configured: Bool,
		for id: ClaudeCodeCompatibleBackendID,
		defaults: UserDefaults = .standard
	) -> Bool {
		ClaudeCodeCompatibleBackendStore(defaults: defaults).setConfigured(configured, for: id)
	}

	static func removedEnvironmentKeys(config: ClaudeCodeCompatibleBackendConfig) -> Set<String> {
		let configuredAuthKey = config.normalized.auth.environmentVariableName
		return Set(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { $0 != configuredAuthKey })
	}

	static func environment(
		config: ClaudeCodeCompatibleBackendConfig,
		apiKey: String
	) -> [String: String] {
		let normalizedConfig = config.normalized
		var environment: [String: String] = [
			"ANTHROPIC_BASE_URL": normalizedConfig.normalizedBaseURL ?? normalizedConfig.baseURL,
			normalizedConfig.auth.environmentVariableName: apiKey
		]

		if normalizedConfig.id == .glmZAI {
			environment["API_TIMEOUT_MS"] = glmTimeoutMilliseconds
		}

		if case .claudeSlotMapping(let mapping) = normalizedConfig.modelBehavior {
			let normalizedMapping = mapping.normalized
			environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = normalizedMapping.haiku
			environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = normalizedMapping.sonnet
			environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = normalizedMapping.opus
		}

		return environment
	}
}
