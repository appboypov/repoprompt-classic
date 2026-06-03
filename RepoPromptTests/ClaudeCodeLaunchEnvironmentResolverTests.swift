import XCTest
@testable import RepoPrompt

final class ClaudeCodeLaunchEnvironmentResolverTests: XCTestCase {
	private var userDefaultsSuites: [String] = []

	override func tearDown() {
		for suite in userDefaultsSuites {
			UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
		}
		userDefaultsSuites = []
		super.tearDown()
	}

	private func makeBackendStore() -> ClaudeCodeCompatibleBackendStore {
		let suiteName = "ClaudeCodeLaunchEnvironmentResolverTests.\(UUID().uuidString)"
		userDefaultsSuites.append(suiteName)
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return ClaudeCodeCompatibleBackendStore(defaults: defaults)
	}

	func testStandardClaudeModelUsesDefaultClaudeBackend() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: {
			XCTFail("Standard Claude models should not request a Z.ai key")
			return nil
		}, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .standard,
			requestedModel: AgentModel.claudeSonnet.rawValue
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeSonnet.rawValue)
		XCTAssertTrue(environment.environmentOverrides.isEmpty)
		XCTAssertEqual(environment.backend, .defaultClaude)
	}

	func testGLMVariantRequiresZAIKey() async {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { nil }, backendStore: makeBackendStore())

		do {
			_ = try await resolver.resolve(
				variant: .glm,
				requestedModel: AgentModel.claudeSonnet.rawValue
			)
			XCTFail("Expected missing Z.ai key to fail")
		} catch let error as AIProviderError {
			guard case .invalidConfiguration(let detail) = error else {
				return XCTFail("Expected invalidConfiguration error, got \(error)")
			}
			XCTAssertTrue(detail.contains("requires a configured API key"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testStandardClaudeVariantRejectsLegacyGLM46Selection() async {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: {
			XCTFail("Standard Claude models should not request a Z.ai key")
			return nil
		}, backendStore: makeBackendStore())

		do {
			_ = try await resolver.resolve(
				variant: .standard,
				requestedModel: AgentModel.glm46.rawValue
			)
			XCTFail("Expected legacy GLM model to be rejected on standard Claude backend")
		} catch let error as AIProviderError {
			guard case .invalidConfiguration(let detail) = error else {
				return XCTFail("Expected invalidConfiguration error, got \(error)")
			}
			XCTAssertTrue(detail.contains("GLM models require the Claude Code GLM agent"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testGLMVariantUsesZAIAnthropicCompatibilityEnvironment() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: AgentModel.claudeOpus.rawValue
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(environment.backend, .compatible(.glmZAI))
		XCTAssertEqual(environment.environmentOverrides["API_TIMEOUT_MS"], "3000000")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_AUTH_TOKEN"], "zai-test-key")
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_API_KEY"])
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-4.7")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-5-turbo")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.1")
	}

	func testGLMVariantDefaultsToClaudeSonnetRequestedModel() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: nil
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeSonnet.rawValue)
	}

	func testGLMVariantUsesEditedBackendSlotMappingsInEnvironment() async throws {
		let store = makeBackendStore()
		var config = store.config(for: .glmZAI)
		config.modelBehavior = .claudeSlotMapping(
			ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
				haiku: "glm-custom-haiku",
				sonnet: "glm-custom-sonnet",
				opus: "glm-custom-opus"
			)
		)
		store.saveConfig(config)
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: store)

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: "glm-custom-opus"
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-custom-haiku")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-custom-sonnet")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-custom-opus")
	}

	func testGLMVariantUsesEditedBackendBaseURLAndAuthStyleInEnvironment() async throws {
		let store = makeBackendStore()
		var config = store.config(for: .glmZAI)
		config.baseURL = "https://glm.example.test/anthropic"
		config.auth = .anthropicAPIKey
		store.saveConfig(config)
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: store)

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: AgentModel.claudeSonnet.rawValue
		)

		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_BASE_URL"], "https://glm.example.test/anthropic")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_API_KEY"], "zai-test-key")
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_AUTH_TOKEN"])
	}

	func testGLMVariantKeepsDefaultRawCompatibilityAfterEditedMappings() async throws {
		let store = makeBackendStore()
		var config = store.config(for: .glmZAI)
		config.modelBehavior = .claudeSlotMapping(
			ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
				haiku: "glm-custom-haiku",
				sonnet: "glm-custom-sonnet",
				opus: "glm-custom-opus"
			)
		)
		store.saveConfig(config)
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: store)

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: "glm-5-turbo"
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeSonnet.rawValue)
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "glm-custom-sonnet")
	}

	func testCompatibleBackendPresetsIncludeKimiAndCustomConfigData() {
		let store = makeBackendStore()

		let kimi = store.config(for: .kimi)
		XCTAssertEqual(kimi.displayName, "CC Moonshot")
		XCTAssertEqual(kimi.baseURL, "https://api.kimi.com/coding/")
		XCTAssertEqual(kimi.auth, .anthropicAPIKey)
		XCTAssertEqual(kimi.modelBehavior, .noModel)

		let custom = store.config(for: .custom)
		XCTAssertEqual(custom.displayName, "CC Custom")
		XCTAssertFalse(custom.isEnabled)
		XCTAssertEqual(custom.auth, .anthropicAPIKey)
		XCTAssertEqual(custom.modelBehavior, .noModel)
	}

	func testKimiVariantUsesNoModelAnthropicAPIKeyEnvironment() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(
			zaiKeyProvider: { nil },
			backendSecretProvider: { id in id == .kimi ? "kimi-test-key" : nil },
			backendStore: makeBackendStore()
		)

		let environment = try await resolver.resolve(
			variant: .kimi,
			requestedModel: AgentModel.kimiCode.rawValue
		)

		XCTAssertNil(environment.effectiveModel)
		XCTAssertEqual(environment.backend, .compatible(.kimi))
		XCTAssertTrue(environment.suppressesEffortSettings)
		XCTAssertTrue(environment.removedEnvironmentKeys.contains("ANTHROPIC_AUTH_TOKEN"))
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_BASE_URL"], "https://api.kimi.com/coding/")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_API_KEY"], "kimi-test-key")
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_AUTH_TOKEN"])
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"])
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"])
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"])
		XCTAssertNil(environment.environmentOverrides["API_TIMEOUT_MS"])
	}

	func testKimiVariantRejectsUnrelatedModelRaw() async {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(
			zaiKeyProvider: { nil },
			backendSecretProvider: { id in id == .kimi ? "kimi-test-key" : nil },
			backendStore: makeBackendStore()
		)

		do {
			_ = try await resolver.resolve(variant: .kimi, requestedModel: AgentModel.claudeSonnet.rawValue)
			XCTFail("Expected Kimi to reject unrelated model selection")
		} catch let error as AIProviderError {
			guard case .invalidConfiguration(let detail) = error else {
				return XCTFail("Expected invalidConfiguration error, got \(error)")
			}
			XCTAssertTrue(detail.contains("Unsupported CC Moonshot model selection"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testCustomNoModelBackendUsesConfiguredEnvironment() async throws {
		let store = makeBackendStore()
		var config = store.config(for: .custom)
		config.isEnabled = true
		config.displayName = "Acme Claude"
		config.baseURL = "https://acme.example/anthropic"
		config.auth = .anthropicAuthToken
		config.modelBehavior = .noModel
		store.saveConfig(config)
		let resolver = ClaudeCodeLaunchEnvironmentResolver(
			zaiKeyProvider: { nil },
			backendSecretProvider: { id in id == .custom ? "custom-key" : nil },
			backendStore: store
		)

		let environment = try await resolver.resolve(
			variant: .customCompatible,
			requestedModel: AgentModel.customClaudeCompatible.rawValue
		)

		XCTAssertNil(environment.effectiveModel)
		XCTAssertEqual(environment.backend, .compatible(.custom))
		XCTAssertTrue(environment.suppressesEffortSettings)
		XCTAssertTrue(environment.removedEnvironmentKeys.contains("ANTHROPIC_API_KEY"))
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_BASE_URL"], "https://acme.example/anthropic")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_AUTH_TOKEN"], "custom-key")
		XCTAssertNil(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"])
	}

	func testCustomSlotMappingBackendUsesSlotsAndMappings() async throws {
		let store = makeBackendStore()
		var config = store.config(for: .custom)
		config.isEnabled = true
		config.baseURL = "https://slot.example/anthropic"
		config.modelBehavior = .claudeSlotMapping(
			ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
				haiku: "slot-haiku",
				sonnet: "slot-sonnet",
				opus: "slot-opus"
			)
		)
		store.saveConfig(config)
		let resolver = ClaudeCodeLaunchEnvironmentResolver(
			zaiKeyProvider: { nil },
			backendSecretProvider: { id in id == .custom ? "custom-key" : nil },
			backendStore: store
		)

		let environment = try await resolver.resolve(
			variant: .customCompatible,
			requestedModel: "slot-opus"
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeOpus.rawValue)
		XCTAssertFalse(environment.suppressesEffortSettings)
		XCTAssertTrue(environment.removedEnvironmentKeys.contains("ANTHROPIC_AUTH_TOKEN"))
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "slot-haiku")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_SONNET_MODEL"], "slot-sonnet")
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "slot-opus")
	}

	func testGLMVariantAcceptsClaudeCodeModelRaws() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: AgentModel.claudeHaiku.rawValue
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeHaiku.rawValue)
	}

	func testGLMVariantNormalizesLegacyGLM46SelectionToHaikuSlot() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: "glm-4.6"
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeHaiku.rawValue)
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm-4.7")
	}

	func testGLMVariantNormalizesLegacyGLM5SelectionToOpusSlot() async throws {
		let resolver = ClaudeCodeLaunchEnvironmentResolver(zaiKeyProvider: { "zai-test-key" }, backendStore: makeBackendStore())

		let environment = try await resolver.resolve(
			variant: .glm,
			requestedModel: "glm-5"
		)

		XCTAssertEqual(environment.effectiveModel, AgentModel.claudeOpus.rawValue)
		XCTAssertEqual(environment.environmentOverrides["ANTHROPIC_DEFAULT_OPUS_MODEL"], "glm-5.1")
	}
}
