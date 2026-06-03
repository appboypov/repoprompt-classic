import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class AgentModelResolutionTests: XCTestCase {
	private final class InMemorySecureKeysService: SecureKeysService {
		private var storage: [String: String] = [:]
		private let lock = NSLock()

		override func saveAPIKey(_ key: String, for identifier: String) throws {
			lock.lock()
			defer { lock.unlock() }
			storage[identifier] = key
		}

		override func getAPIKey(for identifier: String) async throws -> String? {
			lock.lock()
			defer { lock.unlock() }
			return storage[identifier]
		}

		override func deleteAPIKey(for identifier: String) throws {
			lock.lock()
			defer { lock.unlock() }
			storage.removeValue(forKey: identifier)
		}
	}

	private let codexDynamicModelStoreKey = "CodexDynamicModelRecords"

	private func makeDefaults() -> (UserDefaults, String) {
		let suiteName = "AgentModelResolutionTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suiteName)!
		defaults.removePersistentDomain(forName: suiteName)
		return (defaults, suiteName)
	}

	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
		super.tearDown()
	}

	private func withPreservedCodexDynamicModelStore(_ body: () throws -> Void) rethrows {
		let defaults = UserDefaults.standard
		let previousValue = defaults.object(forKey: codexDynamicModelStoreKey)
		defer {
			if let previousValue {
				defaults.set(previousValue, forKey: codexDynamicModelStoreKey)
			} else {
				defaults.removeObject(forKey: codexDynamicModelStoreKey)
			}
		}
		try body()
	}

	private func withPreservedCompatibleBackendConfigs(_ body: () throws -> Void) rethrows {
		let defaults = UserDefaults.standard
		let previousValue = defaults.object(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
		defer {
			if let previousValue {
				defaults.set(previousValue, forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			} else {
				defaults.removeObject(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			}
		}
		try body()
	}

	private func withPreservedCompatibleBackendConfiguredFlags(_ body: () throws -> Void) rethrows {
		let defaults = UserDefaults.standard
		let store = ClaudeCodeCompatibleBackendStore.shared
		let previousValues = Dictionary(uniqueKeysWithValues: ClaudeCodeCompatibleBackendID.allCases.map {
			($0, defaults.object(forKey: store.configuredDefaultsKey(for: $0)))
		})
		defer {
			for id in ClaudeCodeCompatibleBackendID.allCases {
				let key = store.configuredDefaultsKey(for: id)
				if let value = previousValues[id] {
					defaults.set(value, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
		try body()
	}

	private func withPreservedCompatibleBackendState<T>(_ body: () async throws -> T) async rethrows -> T {
		let defaults = UserDefaults.standard
		let store = ClaudeCodeCompatibleBackendStore.shared
		let previousConfigData = defaults.object(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
		let previousConfiguredValues = Dictionary(uniqueKeysWithValues: ClaudeCodeCompatibleBackendID.allCases.map {
			($0, defaults.object(forKey: store.configuredDefaultsKey(for: $0)))
		})
		defer {
			if let previousConfigData {
				defaults.set(previousConfigData, forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			} else {
				defaults.removeObject(forKey: ClaudeCodeCompatibleBackendStore.configsDefaultsKey)
			}
			for id in ClaudeCodeCompatibleBackendID.allCases {
				let key = store.configuredDefaultsKey(for: id)
				if let value = previousConfiguredValues[id] {
					defaults.set(value, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
		return try await body()
	}

	private func withPreservedStandardDefaults<T>(_ keys: [String], body: () async throws -> T) async rethrows -> T {
		let defaults = UserDefaults.standard
		let previousValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
		defer {
			for key in keys {
				if let previousValue = previousValues[key] ?? nil {
					defaults.set(previousValue, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
		return try await body()
	}

	func testResolvesKnownCodexModelDirectly() {
		let resolved = AgentModel.resolvedModel(
			forRaw: AgentModel.codexHigh.rawValue,
			agentKind: .codexExec
		)
		XCTAssertEqual(resolved, .codexHigh)
	}

	func testResolvesCodexBaseIDToMedium() {
		let resolved = AgentModel.resolvedModel(
			forRaw: "gpt-5.3-codex",
			agentKind: .codexExec
		)
		XCTAssertEqual(resolved, .codexMedium)
	}

	func testResolvesCodexBaseIDWithEffortSuffixCaseInsensitively() {
		let resolved = AgentModel.resolvedModel(
			forRaw: "GPT-5.3-CODEX-XHIGH",
			agentKind: .codexExec
		)
		XCTAssertEqual(resolved, .codexXHigh)
	}

	func testResolvesGPT55CodexRawIDsToGPT55Family() {
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.5", agentKind: .codexExec), .gpt55CodexMedium)
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.5-high", agentKind: .codexExec), .gpt55CodexHigh)
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.5-high", agentKind: .codexExec), .gpt55CodexHigh)
	}

	func testResolvesGPT52VariantsToGPT52Family() {
		let resolved = AgentModel.resolvedModel(
			forRaw: "gpt-5.2-codex-high",
			agentKind: .codexExec
		)
		XCTAssertEqual(resolved, .gpt5High)
	}

	func testReturnsNilForUnknownNonCodexModelOnClaude() {
		let resolved = AgentModel.resolvedModel(
			forRaw: "some-unknown-model",
			agentKind: .claudeCode
		)
		XCTAssertNil(resolved)
	}

	func testResolvesLegacyGemini3ProPreviewToGemini31Preview() {
		let resolved = AgentModel.resolvedModel(
			forRaw: "gemini-3-pro-preview",
			agentKind: .gemini
		)
		XCTAssertEqual(resolved, .geminiPro3p1Preview)
	}

	func testOracleExportWorkflowDefaultsToExploreRole() {
		XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)
	}

	@MainActor
	func testOracleExportWorkflowDefaultTaskLabelPrefersGLMWhenCompatibleClaudeBackendsAreAvailable() throws {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: true,
			kimiConfigured: true,
			customClaudeCompatibleConfigured: true
		)

		let selection = try AgentMCPSelectionResolver.resolve(
			modelID: nil,
			defaultTaskLabel: AgentWorkflow.oracleExport.defaultTaskLabelKind,
			availability: availability
		)

		XCTAssertEqual(selection.agentRaw, DiscoverAgentKind.claudeCodeGLM.rawValue)
		XCTAssertEqual(selection.modelRaw, AgentModel.claudeHaiku.rawValue)
		XCTAssertEqual(selection.taskLabelKind, .explore)
	}

	@MainActor
	func testOracleExportWorkflowDefaultTaskLabelFallsBackToKimiThenCustomCompatible() throws {
		let kimiSelection = try AgentMCPSelectionResolver.resolve(
			modelID: nil,
			defaultTaskLabel: AgentWorkflow.oracleExport.defaultTaskLabelKind,
			availability: AgentModelCatalog.AvailabilityContext(
				claudeCodeAvailable: false,
				codexAvailable: false,
				geminiAvailable: false,
				openCodeAvailable: false,
				cursorAvailable: false,
				zaiConfigured: false,
				kimiConfigured: true,
				customClaudeCompatibleConfigured: false
			)
		)

		XCTAssertEqual(kimiSelection.agentRaw, DiscoverAgentKind.kimiCode.rawValue)
		XCTAssertEqual(kimiSelection.modelRaw, AgentModel.kimiCode.rawValue)
		XCTAssertEqual(kimiSelection.taskLabelKind, .explore)

		try withPreservedCompatibleBackendConfigs {
			try withPreservedCompatibleBackendConfiguredFlags {
				var customConfig = ClaudeCodeCompatibleBackendID.custom.defaultPreset
				customConfig.isEnabled = true
				customConfig.baseURL = "https://example.com/anthropic"
				customConfig.modelBehavior = .noModel
				ClaudeCodeCompatibleBackendStore.shared.saveConfig(customConfig)
				_ = ClaudeCodeCompatibleBackendStore.shared.setConfigured(true, for: .custom)

				let customSelection = try AgentMCPSelectionResolver.resolve(
					modelID: nil,
					defaultTaskLabel: AgentWorkflow.oracleExport.defaultTaskLabelKind,
					availability: AgentModelCatalog.AvailabilityContext(
						claudeCodeAvailable: false,
						codexAvailable: false,
						geminiAvailable: false,
						openCodeAvailable: false,
						cursorAvailable: false,
						zaiConfigured: false,
						kimiConfigured: false,
						customClaudeCompatibleConfigured: true
					)
				)

				XCTAssertEqual(customSelection.agentRaw, DiscoverAgentKind.customClaudeCompatible.rawValue)
				XCTAssertEqual(customSelection.modelRaw, AgentModel.customClaudeCompatible.rawValue)
				XCTAssertEqual(customSelection.taskLabelKind, .explore)
			}
		}
	}

	func testClaudeCodeGLMAgentDoesNotExposeGLMModels() {
		let options = AgentModelCatalog.options(
			for: .claudeCode,
			availability: .init(zaiConfigured: true)
		)
		let rawValues = Set(options.map(\.rawValue))

		XCTAssertFalse(rawValues.contains(AgentModel.glm47.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.glm5Turbo.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.glm5.rawValue))
	}

	func testCompatibleBackendsDoNotRequireNativeClaudeCodeAvailability() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			zaiConfigured: true,
			kimiConfigured: true,
			customClaudeCompatibleConfigured: true
		)

		XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.claudeCode, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.claudeCodeGLM, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.kimiCode, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isAgentAvailable(.customClaudeCompatible, availability: availability))
	}

	func testCompatibleBackendUnavailableWhenBackendConfigFlagIsFalse() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			zaiConfigured: false,
			kimiConfigured: false,
			customClaudeCompatibleConfigured: false
		)

		XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.claudeCodeGLM, availability: availability))
		XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.kimiCode, availability: availability))
		XCTAssertFalse(AgentModelCatalog.isAgentAvailable(.customClaudeCompatible, availability: availability))
	}

	func testClaudeModelSpecifierParsesEncodedEffortRaws() {
		let sonnet = ClaudeModelSpecifier(raw: "sonnet:xhigh")
		XCTAssertEqual(sonnet.baseModel, AgentModel.claudeSonnet.rawValue)
		XCTAssertEqual(sonnet.effortLevel, .xhigh)
		XCTAssertEqual(sonnet.runtimeModelParam, AgentModel.claudeSonnet.rawValue)

		let opus1m = ClaudeModelSpecifier(raw: "opus[1m]:max")
		XCTAssertEqual(opus1m.baseModel, AgentModel.claudeOpus1m.rawValue)
		XCTAssertEqual(opus1m.effortLevel, .max)
		XCTAssertEqual(opus1m.runtimeModelParam, AgentModel.claudeOpus1m.rawValue)

		let plain = ClaudeModelSpecifier(raw: "sonnet")
		XCTAssertEqual(plain.baseModel, AgentModel.claudeSonnet.rawValue)
		XCTAssertNil(plain.effortLevel)

		let encodedDefault = ClaudeModelSpecifier(raw: "default:x-high")
		XCTAssertNil(encodedDefault.baseModel)
		XCTAssertEqual(encodedDefault.effortLevel, .xhigh)
		XCTAssertNil(encodedDefault.runtimeModelParam)

		let unknownEffort = ClaudeModelSpecifier(raw: "sonnet:ultra")
		XCTAssertEqual(unknownEffort.baseModel, "sonnet:ultra")
		XCTAssertNil(unknownEffort.effortLevel)
	}

	func testClaudeEncodedModelResolutionAndValidation() {
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: AgentModel.claudeSonnet.rawValue, agentKind: .claudeCode),
			.claudeSonnet
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "sonnet:xhigh", agentKind: .claudeCode),
			.claudeSonnet
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "opus:xhigh", agentKind: .claudeCode),
			.claudeOpus
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "opus[1m]:max", agentKind: .claudeCode),
			.claudeOpus1m
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "default:xhigh", agentKind: .claudeCode),
			.defaultModel
		)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.claudeSonnet.rawValue, for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "opus:xhigh", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "opus[1m]:xhigh", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "opus[1m]:max", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "sonnet:xhigh", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "haiku:xhigh", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "default:xhigh", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "sonnet:ultra", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "glm-4.7:xhigh", for: .claudeCodeGLM, availability: .init(zaiConfigured: true)))
	}

	func testClaudeMenuGroupsExpandedEffortOptions() throws {
		let options = AgentModelCatalog.options(for: .claudeCode)
		let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCode)
		let sonnetGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeSonnet.rawValue })
		let opusGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeOpus.rawValue })
		let haikuGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeHaiku.rawValue })
		let opus1mGroup = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeOpus1m.rawValue })

		XCTAssertEqual(menu.defaultOption?.rawValue, AgentModel.defaultModel.rawValue)
		XCTAssertEqual(menu.groups.map(\.displayName), [
			"Opus Latest (1M)",
			"Opus Latest",
			"Opus 4.7",
			"Opus 4.6",
			"Opus 4.5",
			"Sonnet Latest",
			"Sonnet 4.6",
			"Sonnet 4.5",
			"Haiku Latest",
			"Haiku 4.5"
		])
		XCTAssertEqual(sonnetGroup.options.map(\.rawValue), [
			"sonnet:low",
			"sonnet:medium",
			"sonnet:high",
			"sonnet:max"
		])
		XCTAssertEqual(haikuGroup.options.map(\.rawValue), [
			"haiku:low",
			"haiku:medium",
			"haiku:high",
			"haiku:max"
		])
		XCTAssertTrue(opusGroup.options.contains { $0.rawValue == "opus:xhigh" })
		XCTAssertTrue(opus1mGroup.options.contains { $0.rawValue == "opus[1m]:xhigh" })
		XCTAssertFalse(sonnetGroup.options.contains { $0.rawValue.hasSuffix(":xhigh") })
		XCTAssertEqual(sonnetGroup.options.compactMap { ClaudeModelSpecifier(raw: $0.rawValue).effortLevel }, [.low, .medium, .high, .max])
	}

	func testClaudeAliasDisplayLabelsUseLatestSuffix() {
		XCTAssertEqual(AgentModel.claudeSonnet.displayName, "Sonnet Latest")
		XCTAssertEqual(AgentModel.claudeOpus.displayName, "Opus Latest")
		XCTAssertEqual(AgentModel.claudeHaiku.displayName, "Haiku Latest")
		// opus[1m] uses the Opus Latest prefix and preserves its (1M) context marker.
		XCTAssertEqual(AgentModel.claudeOpus1m.displayName, "Opus Latest (1M)")
	}

	func testClaudeCodeDefaultResolvesToOpusLatestAlias() {
		XCTAssertEqual(
			AgentModelCatalog.defaultModelRaw(for: .claudeCode),
			AgentModel.claudeOpus.rawValue
		)

		let normalized = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: nil
		)
		XCTAssertEqual(normalized.agent, .claudeCode)
		XCTAssertEqual(normalized.modelRaw, AgentModel.claudeOpus.rawValue)

		XCTAssertEqual(
			AgentModelCatalog.displayName(for: normalized.modelRaw, agentKind: .claudeCode),
			"Opus Latest"
		)

		// Explicit 'default' raw stays valid for back-compat, but is not the resolved default.
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.defaultModel.rawValue, for: .claudeCode))
	}

	func testClaudeCodeGLMDefaultUnchangedByClaudeCodeDefaultChange() {
		let normalized = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.claudeCodeGLM.rawValue,
			modelRaw: nil,
			availability: .init(zaiConfigured: true)
		)

		XCTAssertEqual(normalized.agent, .claudeCodeGLM)
		XCTAssertEqual(normalized.modelRaw, AgentModel.claudeSonnet.rawValue)
	}

	func testResolvesClaudeFullModelIDsDirectly() {
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-opus-4-5", agentKind: .claudeCode),
			.claudeOpus45
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-opus-4-6", agentKind: .claudeCode),
			.claudeOpus46
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-opus-4-7", agentKind: .claudeCode),
			.claudeOpus47
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-sonnet-4-5", agentKind: .claudeCode),
			.claudeSonnet45
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-sonnet-4-6", agentKind: .claudeCode),
			.claudeSonnet46
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-haiku-4-5", agentKind: .claudeCode),
			.claudeHaiku45
		)
	}

	func testResolvesClaudeFullModelIDsWithEncodedEffortSuffix() {
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-opus-4-6:xhigh", agentKind: .claudeCode),
			.claudeOpus46
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-opus-4-7:xhigh", agentKind: .claudeCode),
			.claudeOpus47
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-sonnet-4-5:high", agentKind: .claudeCode),
			.claudeSonnet45
		)
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "claude-haiku-4-5:low", agentKind: .claudeCode),
			.claudeHaiku45
		)
	}

	func testClaudeFullOpusIDsSupportXHighButSonnetAndHaikuDoNot() {
		// Plain full IDs are valid.
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-5", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-6", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-7", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-4-5", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-4-6", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-haiku-4-5", for: .claudeCode))

		// Opus full IDs support xhigh.
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-5:xhigh", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-6:xhigh", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-7:xhigh", for: .claudeCode))

		// Sonnet/Haiku full IDs do NOT support xhigh.
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "claude-sonnet-4-5:xhigh", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "claude-sonnet-4-6:xhigh", for: .claudeCode))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "claude-haiku-4-5:xhigh", for: .claudeCode))

		// Non-xhigh efforts remain valid across all full IDs.
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-sonnet-4-6:high", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-haiku-4-5:low", for: .claudeCode))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "claude-opus-4-6:medium", for: .claudeCode))
	}

	func testClaudeFullModelIDsAppearInClaudeCodeMenu() throws {
		let options = AgentModelCatalog.options(for: .claudeCode)
		let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCode)
		let groupRawValues = Set(menu.groups.map(\.baseModelRaw))

		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeOpus45.rawValue))
		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeOpus46.rawValue))
		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeOpus47.rawValue))
		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeSonnet45.rawValue))
		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeSonnet46.rawValue))
		XCTAssertTrue(groupRawValues.contains(AgentModel.claudeHaiku45.rawValue))

		// Opus full IDs expose xhigh options.
		let opus47Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeOpus47.rawValue })
		XCTAssertTrue(opus47Group.options.contains { $0.rawValue == "claude-opus-4-7:xhigh" })
		let opus46Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeOpus46.rawValue })
		XCTAssertTrue(opus46Group.options.contains { $0.rawValue == "claude-opus-4-6:xhigh" })
		let opus45Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeOpus45.rawValue })
		XCTAssertTrue(opus45Group.options.contains { $0.rawValue == "claude-opus-4-5:xhigh" })

		// Sonnet/Haiku full IDs do not expose xhigh options.
		let sonnet46Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeSonnet46.rawValue })
		XCTAssertFalse(sonnet46Group.options.contains { $0.rawValue.hasSuffix(":xhigh") })
		let sonnet45Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeSonnet45.rawValue })
		XCTAssertFalse(sonnet45Group.options.contains { $0.rawValue.hasSuffix(":xhigh") })
		let haiku45Group = try XCTUnwrap(menu.groups.first { $0.baseModelRaw == AgentModel.claudeHaiku45.rawValue })
		XCTAssertFalse(haiku45Group.options.contains { $0.rawValue.hasSuffix(":xhigh") })
	}

	func testClaudeCodeGLMDoesNotExposeClaudeFullModelIDs() {
		let options = AgentModelCatalog.options(
			for: .claudeCodeGLM,
			availability: .init(zaiConfigured: true)
		)
		let rawValues = Set(options.map(\.rawValue))

		XCTAssertFalse(rawValues.contains(AgentModel.claudeOpus45.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.claudeOpus46.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.claudeOpus47.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.claudeSonnet45.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.claudeSonnet46.rawValue))
		XCTAssertFalse(rawValues.contains(AgentModel.claudeHaiku45.rawValue))

		// GLM agent also rejects Claude full IDs at the validator.
		XCTAssertFalse(
			AgentModelCatalog.isValid(
				rawModel: AgentModel.claudeOpus46.rawValue,
				for: .claudeCodeGLM,
				availability: .init(zaiConfigured: true)
			)
		)
		XCTAssertFalse(
			AgentModelCatalog.isValid(
				rawModel: "claude-opus-4-6:xhigh",
				for: .claudeCodeGLM,
				availability: .init(zaiConfigured: true)
			)
		)
	}

	func testClaudeGLMMenuGroupsExpandedEffortOptions() {
		let options = AgentModelCatalog.options(
			for: .claudeCodeGLM,
			availability: .init(zaiConfigured: true)
		)
		let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCodeGLM)

		XCTAssertNil(menu.defaultOption)
		XCTAssertEqual(menu.groups.map(\.displayName), ["GLM 4.7", "GLM 5 Turbo", "GLM 5.1"])
		XCTAssertEqual(menu.groups.map(\.baseModelRaw), [
			AgentModel.claudeHaiku.rawValue,
			AgentModel.claudeSonnet.rawValue,
			AgentModel.claudeOpus.rawValue
		])
		XCTAssertEqual(menu.groups.first?.options.map(\.rawValue), [
			"haiku:low",
			"haiku:medium",
			"haiku:high",
			"haiku:max"
		])
		XCTAssertTrue(menu.groups.allSatisfy(\.rendersAsSubmenu))
		XCTAssertFalse(menu.groups.flatMap(\.options).contains { $0.rawValue.hasSuffix(":xhigh") })
	}

	func testKimiCodeExposesSingleNoModelOptionWithoutEffortVariants() throws {
		let availability = AgentModelCatalog.AvailabilityContext(kimiConfigured: true)
		let options = AgentModelCatalog.options(for: .kimiCode, availability: availability)

		XCTAssertEqual(options.map(\.rawValue), [AgentModel.kimiCode.rawValue])
		XCTAssertEqual(ClaudeCodeCompatibleBackendID.kimi.defaultDisplayName, "CC Moonshot")
		XCTAssertEqual(AgentModel.kimiCode.displayName, "Kimi Code")
		XCTAssertEqual(options.first?.displayName, "Kimi Code")
		XCTAssertEqual(
			AgentModelCatalog.displayName(
				for: AgentModel.kimiCode.rawValue,
				agentKind: .kimiCode,
				availability: availability
			),
			"Kimi Code"
		)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.kimiCode.rawValue, for: .kimiCode, availability: availability))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "kimi-code:high", for: .kimiCode, availability: availability))
		XCTAssertTrue(AgentModelCatalog.supportedClaudeEfforts(forSelectedModelRaw: AgentModel.kimiCode.rawValue, agentKind: .kimiCode).isEmpty)

		let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .kimiCode)
		let kimiGroup = try XCTUnwrap(menu.groups.first)
		XCTAssertFalse(kimiGroup.rendersAsSubmenu)
		let stableItems = AgentModelStableMenuItems.modelItems(
			agentKind: .kimiCode,
			options: options,
			selectedAgent: .kimiCode,
			selectedModelRaw: AgentModel.kimiCode.rawValue
		) { _, _ in }
		let kimiItem = try XCTUnwrap(stableItems.first)
		XCTAssertEqual(stableItems.count, 1)
		XCTAssertEqual(kimiItem.title, options.first?.displayName)
		XCTAssertTrue(kimiItem.isSelected)
	}

	func testCustomNoModelExposesSingleConfiguredDisplayOption() throws {
		try withPreservedCompatibleBackendConfigs {
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(ClaudeCodeCompatibleBackendID.custom.defaultPreset)
			let availability = AgentModelCatalog.AvailabilityContext(customClaudeCompatibleConfigured: true)
			let options = AgentModelCatalog.options(for: .customClaudeCompatible, availability: availability)

			XCTAssertEqual(options.map(\.rawValue), [AgentModel.customClaudeCompatible.rawValue])
			XCTAssertEqual(options.first?.displayName, "CC Custom")
			XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "custom-claude-compatible:max", for: .customClaudeCompatible, availability: availability))
		}
	}

	func testCustomSlotMappingExposesSlotOptionsWithConfiguredLabels() throws {
		try withPreservedCompatibleBackendConfigs {
			var config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
			config.isEnabled = true
			config.modelBehavior = .claudeSlotMapping(
				ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping(
					haiku: "custom-fast",
					sonnet: "custom-balanced",
					opus: "custom-strong"
				)
			)
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(config)
			let availability = AgentModelCatalog.AvailabilityContext(customClaudeCompatibleConfigured: true)
			let baseOptions = AgentModelCatalog.options(
				for: .customClaudeCompatible,
				availability: availability,
				includeClaudeEffortVariants: false
			)

			XCTAssertEqual(baseOptions.map(\.rawValue), ["haiku", "sonnet", "opus"])
			XCTAssertEqual(baseOptions.map(\.displayName), ["custom-fast", "custom-balanced", "custom-strong"])
			XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "custom-balanced", for: .customClaudeCompatible, availability: availability))
			XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "sonnet:high", for: .customClaudeCompatible, availability: availability))
			XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "sonnet:xhigh", for: .customClaudeCompatible, availability: availability))
		}
	}

	func testClaudeSelectionMatchingHandlesLegacyBaseWithLastUsedEffort() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, defaults: defaults)

		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus:xhigh",
			selectedRaw: "opus",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus:high",
			selectedRaw: "opus",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus:xhigh",
			selectedRaw: "opus:xhigh",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus",
			selectedRaw: "opus:xhigh",
			agentKind: .claudeCode,
			defaults: defaults
		))
	}

	func testClaudeSelectionMatchingDefaultsBareModelToHighWithoutSavedEffort() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }

		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "sonnet:high",
			selectedRaw: "sonnet",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "sonnet:medium",
			selectedRaw: "sonnet",
			agentKind: .claudeCode,
			defaults: defaults
		))
	}

	func testClaudeSelectionMatchingUsesPerModelEffort() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		ClaudeAgentToolPreferences.setEffortLevel(.high, forModelRaw: "sonnet", agentKind: .claudeCode, defaults: defaults)
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, forModelRaw: "opus", agentKind: .claudeCode, defaults: defaults)

		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "sonnet:high",
			selectedRaw: "sonnet",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "sonnet:max",
			selectedRaw: "sonnet",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus:xhigh",
			selectedRaw: "opus",
			agentKind: .claudeCode,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "opus:high",
			selectedRaw: "opus",
			agentKind: .claudeCode,
			defaults: defaults
		))
	}

	func testDisplayNameAppendsStoredClaudeEffortForBareModel() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		ClaudeAgentToolPreferences.setEffortLevel(.high, forModelRaw: "sonnet", agentKind: .claudeCode, defaults: defaults)
		ClaudeAgentToolPreferences.setEffortLevel(.xhigh, forModelRaw: "opus", agentKind: .claudeCode, defaults: defaults)

		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "sonnet", agentKind: .claudeCode, defaults: defaults),
			"Sonnet Latest High"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "opus", agentKind: .claudeCode, defaults: defaults),
			"Opus Latest XHigh"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "sonnet:max", agentKind: .claudeCode, defaults: defaults),
			"Sonnet Latest Max"
		)
	}

	func testClaudeCodeGLMAgentAvailabilityDependsOnlyOnZAIConfiguration() {
		XCTAssertFalse(
			AgentModelCatalog.selectableAgents(availability: .init(zaiConfigured: false)).contains(.claudeCodeGLM)
		)
		XCTAssertFalse(
			AgentModelCatalog.selectableAgents(
				availability: .init(claudeCodeAvailable: true, zaiConfigured: false)
			).contains(.claudeCodeGLM)
		)
		XCTAssertTrue(
			AgentModelCatalog.selectableAgents(
				availability: .init(claudeCodeAvailable: false, zaiConfigured: true)
			).contains(.claudeCodeGLM)
		)
		XCTAssertTrue(
			AgentModelCatalog.selectableAgents(availability: .init(zaiConfigured: true)).contains(.claudeCodeGLM)
		)
		XCTAssertFalse(
			AgentModelCatalog.selectableAgents(
				availability: .init(claudeCodeAvailable: false, zaiConfigured: true)
			).contains(.claudeCode)
		)
	}

	func testSelectableAgentsFiltersDisconnectedCLIProviders() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: true,
			zaiConfigured: true
		)

		XCTAssertEqual(
			AgentModelCatalog.selectableAgents(availability: availability),
			[.codexExec, .openCode, .claudeCodeGLM]
		)
	}

	func testNormalizeSelectionFallsBackToConnectedProvider() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: true,
			openCodeAvailable: false,
			zaiConfigured: true
		)

		let normalized = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.claudeCode.rawValue,
			modelRaw: AgentModel.claudeSonnet.rawValue,
			availability: availability
		)

		XCTAssertEqual(normalized.agent, .gemini)
		XCTAssertTrue(
			AgentModelCatalog.isValid(
				rawModel: normalized.modelRaw,
				for: .gemini,
				availability: availability
			)
		)
	}

	func testOpenCodeAgentUsesDefaultFallbackWithoutDiscovery() {
		let availability = AgentModelCatalog.AvailabilityContext(openCodeAvailable: true, zaiConfigured: false)
		let options = AgentModelCatalog.options(for: .openCode, availability: availability)

		XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.openCode))
		XCTAssertEqual(options.map(\.rawValue), [AgentModel.defaultModel.rawValue])
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .openCode, availability: availability), AgentModel.defaultModel.rawValue)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.defaultModel.rawValue, for: .openCode, availability: availability))
		XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "anthropic/claude-sonnet-4", for: .openCode, availability: availability))
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: AgentModel.defaultModel.rawValue, agentKind: .openCode), .defaultModel)
		XCTAssertNil(AgentModel.resolvedModel(forRaw: "anthropic/claude-sonnet-4", agentKind: .openCode))
	}

	func testCursorAvailabilityParticipatesInSupportedCLIProviderChecks() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)

		XCTAssertEqual(AgentModelCatalog.selectableAgents(availability: availability), [.cursor])
		XCTAssertTrue(AgentModelCatalog.hasUnconfiguredSupportedCLIProviders(availableAgents: [.codexExec, .claudeCode, .gemini, .openCode]))
		XCTAssertFalse(AgentModelCatalog.hasUnconfiguredSupportedCLIProviders(availableAgents: [.codexExec, .claudeCode, .gemini, .openCode, .cursor]))
	}

	func testSandboxedDelegateEditSurfaceExcludesCursorButGeneralSelectionKeepsIt() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)

		XCTAssertEqual(
			AgentModelCatalog.selectableAgents(availability: availability, surface: .general),
			[.codexExec, .cursor]
		)
		XCTAssertEqual(
			AgentModelCatalog.selectableAgents(availability: availability, surface: .sandboxedDelegateEdit),
			[.codexExec]
		)
		XCTAssertTrue(AgentModelCatalog.AgentSelectionSurface.general.allows(.cursor))
		XCTAssertFalse(AgentModelCatalog.AgentSelectionSurface.sandboxedDelegateEdit.allows(.cursor))
	}

	func testSandboxedDelegateEditSelectionNormalizesAwayFromCursor() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)

		let regular = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: AgentModel.cursorAuto.rawValue,
			availability: availability,
			surface: .general
		)
		let sandboxed = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: AgentModel.cursorAuto.rawValue,
			availability: availability,
			surface: .sandboxedDelegateEdit
		)
		let persistedSandboxed = AgentModelCatalog.normalizePersistedSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: AgentModel.cursorAuto.rawValue,
			availability: availability,
			surface: .sandboxedDelegateEdit
		)

		XCTAssertEqual(regular.agent, .cursor)
		XCTAssertEqual(regular.modelRaw, AgentModel.cursorAuto.rawValue)
		XCTAssertEqual(sandboxed.agent, .codexExec)
		XCTAssertTrue(
			AgentModelCatalog.isValid(
				rawModel: sandboxed.modelRaw,
				for: .codexExec,
				availability: availability
			)
		)
		XCTAssertEqual(persistedSandboxed.agent, .codexExec)
		XCTAssertTrue(
			AgentModelCatalog.isValid(
				rawModel: persistedSandboxed.modelRaw,
				for: .codexExec,
				availability: availability
			)
		)
	}

	func testCursorAgentUsesAutoFallbackWithoutDiscovery() {
		let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true, zaiConfigured: false)
		let options = AgentModelCatalog.options(for: .cursor, availability: availability)

		XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.cursor))
		XCTAssertEqual(options.map(\.rawValue), [AgentModel.cursorAuto.rawValue, AgentModel.cursorComposer2.rawValue])
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .cursor, availability: availability), AgentModel.cursorAuto.rawValue)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.cursorAuto.rawValue, for: .cursor, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.cursorComposer2.rawValue, for: .cursor, availability: availability))
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: AgentModel.cursorAuto.rawValue, agentKind: .cursor), .cursorAuto)
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: AgentModel.cursorComposer2.rawValue, agentKind: .cursor), .cursorComposer2)
	}

	func testPersistedCursorSelectionPreservesAutoWhenCursorUnavailableAndRegistryCold() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let regular = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: AgentModel.cursorAuto.rawValue,
			availability: availability
		)
		let restored = AgentModelCatalog.normalizePersistedSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: AgentModel.cursorAuto.rawValue,
			availability: availability
		)

		XCTAssertEqual(regular.agent, .codexExec)
		XCTAssertEqual(restored.agent, .cursor)
		XCTAssertEqual(restored.modelRaw, AgentModel.cursorAuto.rawValue)
	}

	func testPersistedCodexSelectionPreservesModelWhenCodexUnavailable() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let regular = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: AgentModel.gpt55CodexHigh.rawValue,
			availability: availability
		)
		let restored = AgentModelCatalog.normalizePersistedSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: AgentModel.gpt55CodexHigh.rawValue,
			availability: availability
		)

		XCTAssertEqual(regular.agent, .claudeCode)
		XCTAssertEqual(restored.agent, .codexExec)
		XCTAssertEqual(restored.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
	}

	func testPersistedSandboxedCodexSelectionPreservesModelWhenCodexUnavailable() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)

		let restored = AgentModelCatalog.normalizePersistedSelection(
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: AgentModel.gpt55CodexHigh.rawValue,
			availability: availability,
			surface: .sandboxedDelegateEdit
		)

		XCTAssertEqual(restored.agent, .codexExec)
		XCTAssertEqual(restored.modelRaw, AgentModel.gpt55CodexHigh.rawValue)
	}

	func testPersistedCursorExactACPValueFallsBackToAutoWhenRegistryCold() {
		let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: false, zaiConfigured: false)

		let restored = AgentModelCatalog.normalizePersistedSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: "composer-2[fast=true]",
			availability: availability
		)

		XCTAssertEqual(restored.agent, .cursor)
		XCTAssertEqual(restored.modelRaw, AgentModel.cursorAuto.rawValue)
	}

	func testCursorCatalogMergesAutoFallbackWithACPDiscoveredModels() {
		let exactComposer2ConfigValue = "composer-2[fast=true]"
		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "default[]",
					displayName: "Auto",
					description: "Cursor-discovered automatic model selection",
					isPlaceholderDefault: false,
					isProviderDefault: true
				),
				AgentModelOption(
					rawValue: exactComposer2ConfigValue,
					displayName: "composer-2",
					description: "Cursor-discovered Composer 2 config value",
					isPlaceholderDefault: false,
					isProviderDefault: false
				),
				AgentModelOption(
					rawValue: "cursor-fast",
					displayName: "Cursor Fast",
					description: "Cursor-discovered fast model",
					isPlaceholderDefault: false,
					isProviderDefault: false
				)
			],
			currentModelRaw: "auto"
		)
		let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true, zaiConfigured: false)

		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .cursor))

		let options = AgentModelCatalog.options(for: .cursor, availability: availability)
		XCTAssertEqual(options.map(\.rawValue), [AgentModel.cursorAuto.rawValue, AgentModel.cursorComposer2.rawValue, "cursor-fast"])
		XCTAssertEqual(options.first?.displayName, "Auto")
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .cursor, availability: availability), AgentModel.cursorAuto.rawValue)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: AgentModel.cursorComposer2.rawValue, for: .cursor, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: exactComposer2ConfigValue, for: .cursor, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "default[]", for: .cursor, availability: availability))
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "auto", for: .cursor, availability: availability))
		let normalizedAutoAlias = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.cursor.rawValue,
			modelRaw: "default[]",
			availability: availability
		)
		XCTAssertEqual(normalizedAutoAlias.modelRaw, AgentModel.cursorAuto.rawValue)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: exactComposer2ConfigValue, agentKind: .cursor, availability: availability),
			"composer-2"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: AgentModel.cursorComposer2.rawValue, agentKind: .cursor, availability: availability),
			"Composer 2"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "auto", agentKind: .cursor, availability: availability),
			"Auto"
		)
	}

	func testTaskLabelFallbacksUseCursorWhenPreferredProvidersAreUnavailable() {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)

		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.explore, availability: availability),
			AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: AgentModel.cursorAuto.rawValue)
		)
		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.engineer, availability: availability),
			AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
		)
		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.pair, availability: availability),
			AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
		)
		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.design, availability: availability),
			AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
		)
	}

	func testCursorTaskLabelFallbackDoesNotPreemptPreferredProvidersExceptDesignCodexFallback() {
		let codexAndCursor = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: true,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)
		let geminiAndCursor = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: false,
			codexAvailable: false,
			geminiAvailable: true,
			openCodeAvailable: false,
			cursorAvailable: true,
			zaiConfigured: false
		)

		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.explore, availability: codexAndCursor),
			AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: AgentModel.gpt55CodexLow.rawValue)
		)
		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.engineer, availability: codexAndCursor),
			AgentModelCatalog.NormalizedAgentSelection(agent: .codexExec, modelRaw: AgentModel.gpt55CodexMedium.rawValue)
		)
		XCTAssertEqual(AgentModelCatalog.resolveTaskLabelKind(.pair, availability: codexAndCursor)?.agent, .codexExec)
		XCTAssertEqual(
			AgentModelCatalog.resolveTaskLabelKind(.design, availability: codexAndCursor),
			AgentModelCatalog.NormalizedAgentSelection(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
		)
		XCTAssertEqual(AgentModelCatalog.resolveTaskLabelKind(.design, availability: geminiAndCursor)?.agent, .gemini)
	}

	func testCursorChatModelsUseAutoFallbackAndDeduplicateACPAutoAliases() {
		let exactComposer2ConfigValue = "composer-2[fast=true]"
		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "default[]",
					displayName: "Auto",
					description: "Cursor automatic model selection",
					isDefault: true
				),
				AgentModelOption(
					rawValue: exactComposer2ConfigValue,
					displayName: "Composer 2",
					description: "Cursor ACP Composer value",
					isDefault: false
				),
				AgentModelOption(
					rawValue: "cursor-fast",
					displayName: "Cursor Fast",
					description: "Fast Cursor model",
					isDefault: false
				)
			],
			currentModelRaw: "auto"
		)

		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .cursor))
		let models = AIModel.modelsForProvider(.cursor)

		XCTAssertEqual(models.map(\.modelName), [AgentModel.cursorAuto.rawValue, exactComposer2ConfigValue, "cursor-fast"])
		XCTAssertEqual(models.first?.displayName, "Auto")
		XCTAssertEqual(AIModel.cursorCustom(name: exactComposer2ConfigValue).displayName, "Composer 2")
		XCTAssertTrue(models.contains(.cursorCustom(name: exactComposer2ConfigValue)))
		XCTAssertFalse(models.contains(.cursorCustom(name: "default[]")))
	}

	func testCursorAIProviderFactoryAndModelMapping() async throws {
		let model = AIModel.cursorCustom(name: AgentModel.cursorAuto.rawValue)

		XCTAssertEqual(model.providerType, .cursor)
		XCTAssertTrue(model.provider == CursorCLIProvider.self)
		XCTAssertEqual(model.rawValue, "cursor_custom_\(AgentModel.cursorAuto.rawValue)")
		XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
		XCTAssertEqual(AIProviderType.displayName(for: .cursor), "Cursor CLI")

		let provider = try await AIProviderFactory.createProvider(for: .cursor, key: "")
		XCTAssertTrue(provider is CursorCLIProvider)
	}

	@MainActor
	func testAPISettingsGLMSecretSaveAndDeleteRefreshesAvailableZAIModels() async throws {
		try await withPreservedCompatibleBackendState {
			try await withPreservedStandardDefaults(["customModelZAI", "preferredComposeModel"]) {
				let keyManager = KeyManager(secureService: InMemorySecureKeysService())
				let viewModel = APISettingsViewModel(
					aiQueriesService: AIQueriesService(keyManager: keyManager),
					keyManager: keyManager,
					loadStoredDataOnInit: false
				)
				viewModel.isZaiKeyValid = false
				viewModel.availableZAIModels = []
				await viewModel.updateAvailableModels()
				XCTAssertFalse(viewModel.availableModels.contains { $0.providerType == .zAI })

				try await viewModel.saveCompatibleBackendSecret("zai-test-key", for: .glmZAI)

				XCTAssertTrue(viewModel.isZaiKeyValid)
				XCTAssertEqual(viewModel.compatibleBackendSecretPresence[.glmZAI], true)
				XCTAssertTrue(viewModel.availableModels.contains { $0.providerType == .zAI })

				try await viewModel.deleteCompatibleBackendSecret(for: .glmZAI)

				XCTAssertFalse(viewModel.isZaiKeyValid)
				XCTAssertEqual(viewModel.compatibleBackendSecretPresence[.glmZAI], false)
				XCTAssertFalse(viewModel.availableModels.contains { $0.providerType == .zAI })
			}
		}
	}

	@MainActor
	func testAPISettingsIncludesCompatibleClaudeBackendModelsForOraclePicker() async throws {
		try await withPreservedCompatibleBackendState {
			let keyManager = KeyManager(secureService: InMemorySecureKeysService())
			let viewModel = APISettingsViewModel(
				aiQueriesService: AIQueriesService(keyManager: keyManager),
				keyManager: keyManager,
				loadStoredDataOnInit: false
			)
			viewModel.isClaudeCodeConnected = false

			let glmConfig = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset
			let kimiConfig = ClaudeCodeCompatibleBackendID.kimi.defaultPreset
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(glmConfig)
			ClaudeCodeCompatibleBackendStore.shared.saveConfig(kimiConfig)
			_ = ClaudeCodeCompatibleBackendStore.shared.setConfigured(true, for: .glmZAI)
			_ = ClaudeCodeCompatibleBackendStore.shared.setConfigured(true, for: .kimi)
			viewModel.compatibleBackendConfigs[.glmZAI] = glmConfig
			viewModel.compatibleBackendConfigs[.kimi] = kimiConfig
			viewModel.compatibleBackendSecretPresence[.glmZAI] = true
			viewModel.compatibleBackendSecretPresence[.kimi] = true

			await viewModel.updateAvailableModels()

			let glmModels = ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI)
			let kimiModels = ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.kimi)
			XCTAssertEqual(glmModels.count, 3)
			XCTAssertEqual(kimiModels.count, 1)
			for model in glmModels + kimiModels {
				XCTAssertTrue(viewModel.availableModels.contains(model), "Expected \(model.rawValue) in Oracle picker models")
				XCTAssertEqual(model.providerType, .claudeCode)
				XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
			}
			XCTAssertFalse(viewModel.availableModels.contains(.claudeCodeSonnet))
		}
	}

	func testClaudeCodePickerMenuIncludesCompatibleBackendGroups() throws {
		try withPreservedCompatibleBackendConfigs {
			try withPreservedCompatibleBackendConfiguredFlags {
				ClaudeCodeCompatibleBackendStore.shared.saveConfig(ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset)
				ClaudeCodeCompatibleBackendStore.shared.saveConfig(ClaudeCodeCompatibleBackendID.kimi.defaultPreset)
				let models = ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.glmZAI)
					+ ClaudeCodeAIModelCatalog.compatibleBackendModelsForPicker(.kimi)

				let menu = AIModel.claudeCodeMenu(for: models)

				let groupNames = menu.groups.map(\.displayName)
				XCTAssertTrue(groupNames.contains("CC Zai"))
				XCTAssertTrue(groupNames.contains("Kimi Code"))
				let glmGroup = try XCTUnwrap(menu.groups.first { $0.displayName == "CC Zai" })
				XCTAssertEqual(glmGroup.options.map(\.displayName), [
					"Haiku - GLM 4.7",
					"Sonnet - GLM 5 Turbo",
					"Opus - GLM 5.1"
				])
			}
		}
	}

	@MainActor
	func testAPISettingsIncludesCursorChatModelsWhenConnected() async {
		let defaults = UserDefaults.standard
		let previousCursorConnected = defaults.object(forKey: "CursorCLIConnected")
		defer {
			if let previousCursorConnected {
				defaults.set(previousCursorConnected, forKey: "CursorCLIConnected")
			} else {
				defaults.removeObject(forKey: "CursorCLIConnected")
			}
		}
		defaults.set(false, forKey: "CursorCLIConnected")
		let keyManager = KeyManager()
		let viewModel = APISettingsViewModel(
			aiQueriesService: AIQueriesService(keyManager: keyManager),
			keyManager: keyManager,
			loadStoredDataOnInit: false
		)

		viewModel.isCursorConnected = true
		await viewModel.updateAvailableModels()

		XCTAssertTrue(viewModel.availableModels.contains(.cursorCustom(name: AgentModel.cursorAuto.rawValue)))
	}

	@MainActor
	func testAPISettingsResetStaleCursorChatSelections() async {
		let store = GlobalSettingsStore.shared
		let previousPreferred = store.preferredComposeModelRaw()
		let previousPlanning = store.planningModelRaw()
		let previousSync = store.syncChatModelWithOracle()
		defer {
			store.setSyncChatModelWithOracle(previousSync)
			store.setPlanningModelRaw(previousPlanning)
			store.setPreferredComposeModelRaw(previousPreferred)
		}

		let keyManager = KeyManager()
		let viewModel = APISettingsViewModel(
			aiQueriesService: AIQueriesService(keyManager: keyManager),
			keyManager: keyManager,
			loadStoredDataOnInit: false
		)
		viewModel.isOpenAIKeyValid = true
		viewModel.isCursorConnected = false
		await viewModel.updateAvailableModels()
		let cursorRaw = AIModel.cursorCustom(name: AgentModel.cursorAuto.rawValue).rawValue
		store.setSyncChatModelWithOracle(false)
		store.setPreferredComposeModelRaw(cursorRaw)

		viewModel.test_resetPreferredModelIfNeeded(for: .cursor)

		let raw = store.preferredComposeModelRaw() ?? ""
		XCTAssertNotEqual(raw, cursorRaw)
		XCTAssertNotEqual(AIModel.fromModelName(raw)?.providerType, .cursor)
	}

	func testOpenCodeCatalogUsesACPDiscoveredModelsWhenPresent() {
		let snapshot = ACPDiscoveredSessionModels(
			options: [
				AgentModelOption(
					rawValue: "anthropic/claude-sonnet-4",
					displayName: "Claude Sonnet 4 via OpenCode",
					description: "OpenCode-discovered Anthropic model",
					isPlaceholderDefault: false,
					isProviderDefault: false
				),
				AgentModelOption(
					rawValue: "openai/gpt-5",
					displayName: "GPT-5 via OpenCode",
					description: "OpenCode-discovered OpenAI model",
					isPlaceholderDefault: false,
					isProviderDefault: true
				)
			],
			currentModelRaw: "openai/gpt-5"
		)

		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(snapshot, for: .openCode))
		let options = AgentModelCatalog.options(for: .openCode)

		XCTAssertEqual(Set(options.map(\.rawValue)), Set(["anthropic/claude-sonnet-4", "openai/gpt-5"]))
		XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .openCode), "openai/gpt-5")
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "anthropic/claude-sonnet-4", for: .openCode))
		XCTAssertEqual(AgentModelCatalog.displayName(for: "openai/gpt-5", agentKind: .openCode), "GPT-5 via OpenCode")
	}

	func testOpenCodeACPProviderFactoryReturnsOpenCodeProvider() {
		let provider = ACPAgentProviderFactory.makeProvider(for: .openCode, modelString: nil)

		XCTAssertEqual(provider?.providerID, .openCode)
	}

	func testClaudeCodeGLMAgentExposesThreeGLMModelsWhenAvailable() {
		let options = AgentModelCatalog.options(
			for: .claudeCodeGLM,
			availability: .init(zaiConfigured: true)
		)
		let menu = AgentModelCatalog.claudeMenu(for: options, agentKind: .claudeCodeGLM)

		XCTAssertEqual(menu.groups.map(\.displayName), ["GLM 4.7", "GLM 5 Turbo", "GLM 5.1"])
		XCTAssertEqual(menu.groups.map(\.options.count), [4, 4, 4])
		XCTAssertFalse(options.contains { $0.rawValue.hasSuffix(":xhigh") })
	}

	func testClaudeCodeGLMSelectionRequiresZAIAvailability() {
		XCTAssertFalse(
			AgentModelCatalog.isValid(
				rawModel: AgentModel.claudeSonnet.rawValue,
				for: .claudeCodeGLM,
				availability: .init(zaiConfigured: false)
			)
		)
		XCTAssertTrue(
			AgentModelCatalog.isValid(
				rawModel: AgentModel.claudeSonnet.rawValue,
				for: .claudeCodeGLM,
				availability: .init(zaiConfigured: true)
			)
		)
	}

	func testClaudeModelRawsBackClaudeCodeGLMAgentSelections() {
		XCTAssertTrue(
			AgentModelCatalog.isValid(
				rawModel: AgentModel.claudeSonnet.rawValue,
				for: .claudeCodeGLM,
				availability: .init(zaiConfigured: true)
			)
		)
		let normalized = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.claudeCodeGLM.rawValue,
			modelRaw: AgentModel.claudeSonnet.rawValue,
			availability: .init(zaiConfigured: true)
		)
		XCTAssertEqual(normalized.agent, .claudeCodeGLM)
		XCTAssertEqual(normalized.modelRaw, AgentModel.claudeSonnet.rawValue)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: normalized.modelRaw, agentKind: .claudeCodeGLM),
			"GLM 5 Turbo"
		)
	}

	func testClaudeCodeGLMDefaultsToClaudeSonnetRaw() {
		let normalized = AgentModelCatalog.normalizeSelection(
			agentRaw: DiscoverAgentKind.claudeCodeGLM.rawValue,
			modelRaw: nil,
			availability: .init(zaiConfigured: true)
		)

		XCTAssertEqual(normalized.agent, .claudeCodeGLM)
		XCTAssertEqual(normalized.modelRaw, AgentModel.claudeSonnet.rawValue)
	}

	func testDecodesLegacyGLM5AgentModelRawValue() throws {
		let decoded = try JSONDecoder().decode(AgentModel.self, from: Data("\"glm-5\"".utf8))
		XCTAssertEqual(decoded, .glm5)

		let encoded = try JSONEncoder().encode(decoded)
		XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"glm-5.1\"")
	}

	func testCodexCatalogMergesStaticFallbackWhenCacheIsStale() {
		let defaults = UserDefaults.standard
		let previousValue = defaults.object(forKey: codexDynamicModelStoreKey)
		defer {
			if let previousValue {
				defaults.set(previousValue, forKey: codexDynamicModelStoreKey)
			} else {
				defaults.removeObject(forKey: codexDynamicModelStoreKey)
			}
		}

		let staleModels = [
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.2-codex",
				model: "gpt-5.2-codex",
				displayName: "gpt-5.2-codex",
				description: "Older codex model",
				isDefault: true,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "low", description: "Low"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "xhigh", description: "XHigh")
				],
				defaultReasoningEffort: "medium"
			)
		]
		CodexDynamicModelStore.save(staleModels, defaults: defaults)

		let options = AgentModelCatalog.options(for: .codexExec, codexDynamicModels: [])
		let rawValues = Set(options.map { $0.rawValue.lowercased() })

		XCTAssertTrue(rawValues.contains("gpt-5.2-codex-low"))
		XCTAssertTrue(rawValues.contains(AgentModel.codexLow.rawValue))
	}

	func testCodexStaticCatalogIncludesGPT55RecommendedDefaults() throws {
		try withPreservedCodexDynamicModelStore {
			UserDefaults.standard.removeObject(forKey: codexDynamicModelStoreKey)

			let options = AgentModelCatalog.options(for: .codexExec, codexDynamicModels: [])
			let rawValues = Set(options.map { $0.rawValue.lowercased() })

			XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexLow.rawValue))
			XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexMedium.rawValue))
			XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexHigh.rawValue))
			XCTAssertEqual(AgentModelCatalog.displayName(for: AgentModel.gpt55CodexHigh.rawValue, agentKind: .codexExec, codexDynamicModels: []), "GPT-5.5 High")
		}
	}

	func testCodexCatalogMergesStaticFallbackWhenLiveModelsAreMissingCodex53() {
		let liveModelsMissingCodex53 = [
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.2-codex",
				model: "gpt-5.2-codex",
				displayName: "gpt-5.2-codex",
				description: "Older codex model",
				isDefault: true,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "low", description: "Low"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "xhigh", description: "XHigh")
				],
				defaultReasoningEffort: "medium"
			)
		]

		let options = AgentModelCatalog.options(
			for: .codexExec,
			codexDynamicModels: liveModelsMissingCodex53
		)
		let rawValues = Set(options.map { $0.rawValue.lowercased() })

		XCTAssertTrue(rawValues.contains("gpt-5.2-codex-low"))
		XCTAssertTrue(rawValues.contains(AgentModel.codexLow.rawValue))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexLow.rawValue))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexMedium.rawValue))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexHigh.rawValue))
	}

	func testCodexCatalogDoesNotDuplicateGPT55StaticDefaultsWhenLiveModelsIncludeThem() {
		let liveModels = [
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.5",
				model: "gpt-5.5",
				displayName: "GPT-5.5",
				description: "GPT-5.5 model",
				isDefault: true,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "low", description: "Low"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High")
				],
				defaultReasoningEffort: "medium"
			),
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.3-codex",
				model: "gpt-5.3-codex",
				displayName: "GPT-5.3 Codex",
				description: "Context Builder model",
				isDefault: false,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium")
				],
				defaultReasoningEffort: "medium"
			)
		]

		let options = AgentModelCatalog.options(for: .codexExec, codexDynamicModels: liveModels)
		XCTAssertEqual(options.filter { $0.rawValue == AgentModel.gpt55CodexLow.rawValue }.count, 1)
		XCTAssertEqual(options.filter { $0.rawValue == AgentModel.gpt55CodexMedium.rawValue }.count, 1)
		XCTAssertEqual(options.filter { $0.rawValue == AgentModel.gpt55CodexHigh.rawValue }.count, 1)
		XCTAssertTrue(options.contains { $0.displayName == "GPT-5.5 Low" })
		XCTAssertTrue(options.contains { $0.displayName == "GPT-5.5 Medium" })
		XCTAssertTrue(options.contains { $0.displayName == "GPT-5.5 High" })
	}

	func testCodexCatalogSeparatesPlaceholderDefaultFromProviderDefault() {
		let liveModels = [
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.3-codex",
				model: "gpt-5.3-codex",
				displayName: "gpt-5.3-codex",
				description: "Latest codex model",
				isDefault: true,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium")
				],
				defaultReasoningEffort: "medium"
			)
		]

		let options = AgentModelCatalog.options(
			for: .codexExec,
			codexDynamicModels: liveModels
		)
		let placeholder = options.first { $0.rawValue == AgentModel.defaultModel.rawValue }
		let providerDefault = options.first { $0.rawValue == "gpt-5.3-codex-medium" }

		XCTAssertTrue(placeholder?.isPlaceholderDefault == true)
		XCTAssertFalse(placeholder?.isProviderDefault == true)
		XCTAssertFalse(providerDefault?.isPlaceholderDefault == true)
		XCTAssertTrue(providerDefault?.isProviderDefault == true)
	}

	func testCodexStaticCatalogIncludesSynthesizedGPT54FastVariants() throws {
		try withPreservedCodexDynamicModelStore {
			UserDefaults.standard.removeObject(forKey: codexDynamicModelStoreKey)

			let options = AgentModelCatalog.options(for: .codexExec, codexDynamicModels: [])
			let rawValues = Set(options.map { $0.rawValue.lowercased() })
			let fastHigh = try XCTUnwrap(options.first { $0.rawValue == "gpt-5.4-fast-high" })

			XCTAssertTrue(rawValues.contains("gpt-5.4-fast-low"))
			XCTAssertTrue(rawValues.contains("gpt-5.4-fast-medium"))
			XCTAssertTrue(rawValues.contains("gpt-5.4-fast-high"))
			XCTAssertTrue(rawValues.contains("gpt-5.4-fast-xhigh"))
			XCTAssertEqual(fastHigh.displayName, "GPT-5.4 Fast High")
			XCTAssertTrue(fastHigh.description?.contains("2× faster") == true)
			XCTAssertFalse(fastHigh.isProviderDefault)
		}
	}

	func testCodexDynamicCatalogSynthesizesGPT53AndNewerFastVariantsWithoutReplacingDiscovery() throws {
		let liveModels = [
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.4",
				model: "gpt-5.4",
				displayName: "GPT-5.4",
				description: "Latest GPT-5.4 model",
				isDefault: true,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "low", description: "Low"),
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High")
				],
				defaultReasoningEffort: "high"
			),
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.5",
				model: "gpt-5.5",
				displayName: "GPT-5.5",
				description: "Future GPT model",
				isDefault: false,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium")
				],
				defaultReasoningEffort: "medium"
			),
			CodexAppServerClient.RemoteModel(
				id: "gpt-5.3-codex",
				model: "gpt-5.3-codex",
				displayName: "GPT-5.3 Codex",
				description: "Current Codex model",
				isDefault: false,
				supportedReasoningEfforts: [
					CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium")
				],
				defaultReasoningEffort: "medium"
			)
		]

		let options = AgentModelCatalog.options(for: .codexExec, codexDynamicModels: liveModels)
		let rawValues = Set(options.map { $0.rawValue.lowercased() })
		let dynamicDefault = try XCTUnwrap(options.first { $0.rawValue == "gpt-5.4-high" })
		let synthesizedFast = try XCTUnwrap(options.first { $0.rawValue == "gpt-5.4-fast-high" })

		XCTAssertTrue(rawValues.contains("gpt-5.4-low"))
		XCTAssertTrue(rawValues.contains("gpt-5.4-high"))
		XCTAssertTrue(rawValues.contains("gpt-5.4-fast-low"))
		XCTAssertTrue(rawValues.contains("gpt-5.4-fast-high"))
		XCTAssertTrue(rawValues.contains("gpt-5.5-fast-medium"))
		XCTAssertTrue(rawValues.contains("gpt-5.3-codex-fast-medium"))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexLow.rawValue))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexMedium.rawValue))
		XCTAssertTrue(rawValues.contains(AgentModel.gpt55CodexHigh.rawValue))
		XCTAssertTrue(rawValues.contains("gpt-5.4-fast-medium"))
		XCTAssertTrue(dynamicDefault.isProviderDefault)
		XCTAssertFalse(synthesizedFast.isProviderDefault)
		XCTAssertEqual(synthesizedFast.displayName, "GPT-5.4 Fast High")
		XCTAssertTrue(synthesizedFast.description?.contains(CodexServiceTierVariantCatalog.fastCostWarningText) == true)
	}

	func testCodexFastVariantHelperDetectsServiceTierAndBuildsIDsForGPT53AndNewer() {
		XCTAssertTrue(CodexServiceTierVariantCatalog.isFastVariant(rawModel: "gpt-5.3-codex-fast-high"))
		XCTAssertTrue(CodexServiceTierVariantCatalog.isFastVariant(rawModel: "gpt-5.4-fast-high"))
		XCTAssertTrue(CodexServiceTierVariantCatalog.isFastVariant(rawModel: "gpt-5.5-fast-high"))
		XCTAssertTrue(CodexServiceTierVariantCatalog.isFastVariant(rawModel: "gpt-6-fast-high"))
		XCTAssertEqual(CodexServiceTierVariantCatalog.serviceTierAwareBaseID(for: "gpt-5.4-fast-high"), "gpt-5.4-fast")
		XCTAssertEqual(
			CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.4", reasoningEffort: .high),
			"gpt-5.4-fast-high"
		)
		XCTAssertEqual(
			CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.5", reasoningEffort: .medium),
			"gpt-5.5-fast-medium"
		)
		XCTAssertEqual(
			CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.3-codex", reasoningEffort: .high),
			"gpt-5.3-codex-fast-high"
		)
		XCTAssertNil(CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.2", reasoningEffort: .high))
		XCTAssertFalse(CodexServiceTierVariantCatalog.isFastVariant(rawModel: "gpt-5.2-fast-high"))
	}

	func testCodexMenuSeparatesFastServiceTierGroup() throws {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "gpt-5.4-high", displayName: "GPT-5.4 High", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.4-low", displayName: "GPT-5.4 Low", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.4-fast-high", displayName: "GPT-5.4 Fast High", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.4-fast-medium", displayName: "GPT-5.4 Fast Medium", description: nil, isDefault: false)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)
		let normalGroup = try XCTUnwrap(menu.groups.first { $0.baseModelID == "gpt-5.4" })
		let fastGroup = try XCTUnwrap(menu.groups.first { $0.baseModelID == "gpt-5.4-fast" })

		XCTAssertEqual(Set(menu.groups.map(\.displayName)), Set(["GPT-5.4", "GPT-5.4 Fast"]))
		XCTAssertEqual(normalGroup.options.map(\.rawValue), ["gpt-5.4-low", "gpt-5.4-high"])
		XCTAssertEqual(fastGroup.options.map(\.rawValue), ["gpt-5.4-fast-medium", "gpt-5.4-fast-high"])
	}

	func testCodexFastDisplayNameAndDynamicDiscoveryTags() throws {
		try withPreservedCodexDynamicModelStore {
			UserDefaults.standard.removeObject(forKey: codexDynamicModelStoreKey)

			let displayName = AgentModelCatalog.displayName(
				for: "gpt-5.4-fast-high",
				agentKind: .codexExec,
				codexDynamicModels: []
			)

			XCTAssertEqual(displayName, "GPT-5.4 Fast High")
			XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "gpt-5.4-fast-high", for: .codexExec))
			XCTAssertEqual(AgentModelDiscoveryTag.infer(from: "gpt-5.4-fast-high"), [])
			XCTAssertEqual(AgentModelDiscoveryTag.infer(from: "gpt-5.5-high"), [])
		}
	}

	func testCodexFastStableMenuItemsUseWarningVisuals() throws {
		let normal = AgentModelOption(
			rawValue: "gpt-5.4-high",
			displayName: "GPT-5.4 High",
			description: nil,
			isDefault: false
		)
		let fast = AgentModelOption(
			rawValue: "gpt-5.4-fast-high",
			displayName: "GPT-5.4 Fast High",
			description: nil,
			isDefault: false
		)

		XCTAssertTrue(AgentModelSelectionWarningVisuals.showsWarning(agent: .codexExec, rawModel: fast.rawValue))

		let flatItems = AgentModelStableMenuItems.modelItems(
			agentKind: .codexExec,
			options: [fast],
			selectedAgent: .codexExec,
			selectedModelRaw: fast.rawValue,
			flattenSingleCodexGroups: true
		) { _, _ in }
		let flatFastItem = try XCTUnwrap(flatItems.first)
		XCTAssertEqual(flatFastItem.title, "GPT-5.4 Fast High")
		XCTAssertEqual(flatFastItem.imageSystemName, AgentModelSelectionWarningVisuals.iconSystemName)
		XCTAssertEqual(flatFastItem.style, .warning)
		XCTAssertTrue(flatFastItem.isSelected)

		let groupedItems = AgentModelStableMenuItems.modelItems(
			agentKind: .codexExec,
			options: [normal, fast],
			selectedAgent: .codexExec,
			selectedModelRaw: fast.rawValue,
			flattenSingleCodexGroups: false
		) { _, _ in }
		let normalGroup = try XCTUnwrap(groupedItems.first { $0.title == "GPT-5.4" })
		let fastGroup = try XCTUnwrap(groupedItems.first { $0.title == "GPT-5.4 Fast" })
		XCTAssertNil(normalGroup.imageSystemName)
		XCTAssertEqual(normalGroup.style, .normal)
		XCTAssertEqual(fastGroup.imageSystemName, AgentModelSelectionWarningVisuals.iconSystemName)
		XCTAssertEqual(fastGroup.style, .warning)
	}

	func testCodexSelectionMatchingUsesPerModelReasoningEffort() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.3-codex-high", defaults: defaults)
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.medium, forModelRaw: "gpt-5.4-medium", defaults: defaults)

		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "gpt-5.3-codex-high",
			selectedRaw: "gpt-5.3-codex",
			agentKind: .codexExec,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "gpt-5.3-codex-medium",
			selectedRaw: "gpt-5.3-codex",
			agentKind: .codexExec,
			defaults: defaults
		))
		XCTAssertTrue(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "gpt-5.4-medium",
			selectedRaw: "gpt-5.4",
			agentKind: .codexExec,
			defaults: defaults
		))
		XCTAssertFalse(AgentModelCatalog.modelOptionIsSelected(
			optionRaw: "gpt-5.4-high",
			selectedRaw: "gpt-5.4",
			agentKind: .codexExec,
			defaults: defaults
		))
	}

	func testCodexDisplayNameAppendsStoredReasoningEffortForBareModel() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.high, forModelRaw: "gpt-5.3-codex-high", defaults: defaults)
		CodexAgentToolPreferences.setLastUsedReasoningEffort(.medium, forModelRaw: "gpt-5.4-medium", defaults: defaults)

		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "gpt-5.3-codex", agentKind: .codexExec, defaults: defaults),
			"GPT-5.3 Codex High"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "gpt-5.4", agentKind: .codexExec, defaults: defaults),
			"GPT-5.4 Medium"
		)
		XCTAssertEqual(
			AgentModelCatalog.displayName(for: "gpt-5.4-high", agentKind: .codexExec, defaults: defaults),
			"GPT-5.4 High"
		)
	}

	func testUpdateLastUsedEffortIfEncodedPersistsClaudeAndCodexSelections() {
		let (defaults, suiteName) = makeDefaults()
		defer { defaults.removePersistentDomain(forName: suiteName) }

		XCTAssertTrue(AgentModelCatalog.updateLastUsedEffortIfEncoded(
			agentKind: .claudeCode,
			rawModel: "opus:xhigh",
			defaults: defaults
		))
		XCTAssertEqual(
			ClaudeAgentToolPreferences.effortLevel(forModelRaw: "opus", agentKind: .claudeCode, defaults: defaults),
			.xhigh
		)

		XCTAssertTrue(AgentModelCatalog.updateLastUsedEffortIfEncoded(
			agentKind: .codexExec,
			rawModel: "gpt-5.4-high",
			defaults: defaults
		))
		XCTAssertEqual(
			CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: "gpt-5.4", defaults: defaults),
			.high
		)
	}

	func testCodexMenuGroupsByBaseModelAndSortsByEffort() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: AgentModel.defaultModel.rawValue,
				displayName: AgentModel.defaultModel.displayName,
				description: nil,
				isPlaceholderDefault: true,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-high",
				displayName: "GPT-5.2 High",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-xhigh",
				displayName: "GPT-5.3 Codex XHigh",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-low",
				displayName: "GPT-5.3 Codex Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-low",
				displayName: "GPT-5.2 Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-medium",
				displayName: "GPT-5.3 Codex Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: true
			)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)

		XCTAssertEqual(menu.defaultOption?.rawValue, AgentModel.defaultModel.rawValue)
		XCTAssertEqual(menu.groups.map(\.displayName), ["GPT-5.3 Codex", "GPT-5.2"])
		XCTAssertEqual(
			menu.groups.first?.options.map(\.rawValue),
			["gpt-5.3-codex-low", "gpt-5.3-codex-medium", "gpt-5.3-codex-xhigh"]
		)
		XCTAssertEqual(
			menu.groups.last?.options.map(\.rawValue),
			["gpt-5.2-low", "gpt-5.2-high"]
		)
	}

	func testCodexMenuStripsEffortFromGroupDisplayName() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: "gpt-5.1-codex-max-medium",
				displayName: "GPT-5.1 Codex Max Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.1-codex-max-high",
				displayName: "GPT-5.1 Codex Max High",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)
		XCTAssertEqual(menu.groups.count, 1)
		XCTAssertEqual(menu.groups.first?.displayName, "GPT-5.1 Codex Max")
		XCTAssertEqual(
			menu.groups.first?.options.map(\.rawValue),
			["gpt-5.1-codex-max-medium", "gpt-5.1-codex-max-high"]
		)
	}

	func testCodexMenuKeepsDistinctLabelsForGPT52AndGPT52Codex() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: "gpt-5.2-low",
				displayName: "GPT-5.2 Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-codex-low",
				displayName: "GPT-5.2 Codex Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-codex-medium",
				displayName: "GPT-5.2 Codex Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)
		let names = Set(menu.groups.map(\.displayName))

		XCTAssertTrue(names.contains("GPT-5.2"))
		XCTAssertTrue(names.contains("GPT-5.2 Codex"))
		XCTAssertEqual(menu.groups.count, 2)
	}

	func testCodexMenuKeepsSparkVariantAsDistinctGroup() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: "gpt-5.3-codex-low",
				displayName: "GPT-5.3 Codex Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-medium",
				displayName: "GPT-5.3 Codex Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-spark-low",
				displayName: "GPT-5.3 Codex Spark Low",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-spark-medium",
				displayName: "GPT-5.3 Codex Spark Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)
		let groupNames = Set(menu.groups.map(\.displayName))

		XCTAssertTrue(groupNames.contains("GPT-5.3 Codex"))
		XCTAssertTrue(groupNames.contains("GPT-5.3 Codex Spark"))
		XCTAssertEqual(menu.groups.count, 2)
	}

	func testOpenCodeMenuGroupsParenthesizedVariantsUnderBaseWithDefault() {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "opencode/zen/big-pickle", displayName: "OpenCode Zen/Big Pickle", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/big-pickle/high", displayName: "OpenCode Zen/Big Pickle (high)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/big-pickle/max", displayName: "OpenCode Zen/Big Pickle (max)", description: nil, isDefault: false)
		]

		let menu = AgentModelCatalog.openCodeMenu(for: options)

		XCTAssertEqual(menu.groups.count, 1)
		XCTAssertEqual(menu.groups.first?.displayName, "OpenCode Zen/Big Pickle")
		XCTAssertEqual(menu.groups.first?.rendersAsSubmenu, true)
		XCTAssertEqual(menu.groups.first?.options.map(\.displayName), ["Default", "High", "Max"])
		XCTAssertEqual(menu.groups.first?.options.map { $0.option.rawValue }, [
			"opencode/zen/big-pickle",
			"opencode/zen/big-pickle/high",
			"opencode/zen/big-pickle/max"
		])
	}

	func testOpenCodeMenuDetectsRawSlashVariantsAndNormalizesAliases() {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "opencode/zen/gpt-5-nano/high", displayName: "OpenCode Zen/GPT-5 Nano", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/gpt-5-nano/minimal", displayName: "OpenCode Zen/GPT-5 Nano (minimal)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/gpt-5-nano/med", displayName: "OpenCode Zen/GPT-5 Nano (med)", description: nil, isDefault: false)
		]

		let group = AgentModelCatalog.openCodeMenu(for: options).groups.first

		XCTAssertEqual(group?.displayName, "OpenCode Zen/GPT-5 Nano")
		XCTAssertEqual(group?.rendersAsSubmenu, true)
		XCTAssertEqual(group?.options.map(\.displayName), ["Minimal", "Medium", "High"])
		XCTAssertEqual(group?.options.map { $0.option.rawValue }, [
			"opencode/zen/gpt-5-nano/minimal",
			"opencode/zen/gpt-5-nano/med",
			"opencode/zen/gpt-5-nano/high"
		])
	}

	func testOpenCodeMenuLeavesSingleBaseModelAsDirectItem() {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "opencode/zen/tiny-cucumber", displayName: "OpenCode Zen/Tiny Cucumber", description: nil, isDefault: false)
		]

		let group = AgentModelCatalog.openCodeMenu(for: options).groups.first

		XCTAssertEqual(group?.displayName, "OpenCode Zen/Tiny Cucumber")
		XCTAssertEqual(group?.modelDisplayName, "Tiny Cucumber")
		XCTAssertEqual(group?.rendersAsSubmenu, false)
		XCTAssertEqual(group?.options.first?.displayName, "Tiny Cucumber")
		XCTAssertEqual(group?.options.first?.option.rawValue, "opencode/zen/tiny-cucumber")
	}

	func testOpenCodeMenuSplitsProviderLevelGroupsAboveModelsAndVariants() {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "opencode/zen/gpt-5", displayName: "OpenCode Zen/GPT-5", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/gpt-5/high", displayName: "OpenCode Zen/GPT-5 (high)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/zen/claude-haiku-4-5", displayName: "OpenCode Zen/Claude Haiku 4.5", description: nil, isDefault: false),
			AgentModelOption(rawValue: "minimax-m2.5-free", displayName: "OpenCode Zen/MiniMax M2.5 Free", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/openai/gpt-5", displayName: "OpenCode OpenAI/GPT-5", description: nil, isDefault: false)
		]

		let menu = AgentModelCatalog.openCodeMenu(for: options)

		let zenGroups = menu.providerGroups.first?.groups ?? []
		XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Zen", "OpenAI"])
		XCTAssertEqual(menu.providerGroups.map(\.rendersAsSubmenu), [true, true])
		XCTAssertEqual(zenGroups.map(\.modelDisplayName), ["GPT-5", "Claude Haiku 4.5", "MiniMax M2.5 Free"])
		XCTAssertEqual(zenGroups.first?.rendersAsSubmenu, true)
		XCTAssertEqual(zenGroups.first?.options.map(\.displayName), ["Default", "High"])
		XCTAssertEqual(zenGroups.dropFirst().map(\.rendersAsSubmenu), [false, false])
		XCTAssertEqual(zenGroups.dropFirst().flatMap { $0.options.first?.displayName }, ["Claude Haiku 4.5", "MiniMax M2.5 Free"])
	}

	func testOpenCodeMenuTreatsNoneAsVariantWithoutSplittingZenProvider() {
		let options: [AgentModelOption] = [
			AgentModelOption(rawValue: "opencode/gpt-5.4", displayName: "Zen/GPT-5.4", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/gpt-5.4/none", displayName: "Zen/GPT-5.4 (none)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/gpt-5.4/high", displayName: "Zen/GPT-5.4 (high)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/gpt-5.4-mini", displayName: "Zen/GPT-5.4 mini", description: nil, isDefault: false),
			AgentModelOption(rawValue: "opencode/gpt-5.4-mini/none", displayName: "Zen/GPT-5.4 mini (none)", description: nil, isDefault: false),
			AgentModelOption(rawValue: "openai/gpt-5.4", displayName: "OpenAI/GPT-5.4", description: nil, isDefault: false),
			AgentModelOption(rawValue: "openai/gpt-5.4/none", displayName: "OpenAI/GPT-5.4 (none)", description: nil, isDefault: false)
		]

		let menu = AgentModelCatalog.openCodeMenu(for: options)

		XCTAssertEqual(menu.providerGroups.map(\.displayName), ["Zen", "OpenAI"])
		XCTAssertEqual(menu.providerGroups.filter { $0.displayName == "Zen" }.count, 1)
		let zenGroups = menu.providerGroups.first { $0.displayName == "Zen" }?.groups ?? []
		XCTAssertEqual(zenGroups.map(\.modelDisplayName), ["GPT-5.4", "GPT-5.4 mini"])
		XCTAssertEqual(zenGroups.first?.options.map(\.displayName), ["Default", "None", "High"])
		XCTAssertEqual(zenGroups.first?.options.map { $0.option.rawValue }, [
			"opencode/gpt-5.4",
			"opencode/gpt-5.4/none",
			"opencode/gpt-5.4/high"
		])
	}

	func testCodexMenuOrdersVersionFamiliesDescending() {
		let options: [AgentModelOption] = [
			AgentModelOption(
				rawValue: "gpt-5.1-medium",
				displayName: "GPT-5.1 Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.2-codex-medium",
				displayName: "GPT-5.2 Codex Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-spark-medium",
				displayName: "GPT-5.3 Codex Spark Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.1-codex-max-medium",
				displayName: "GPT-5.1 Codex Max Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			),
			AgentModelOption(
				rawValue: "gpt-5.3-codex-medium",
				displayName: "GPT-5.3 Codex Medium",
				description: nil,
				isPlaceholderDefault: false,
				isProviderDefault: false
			)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)
		let families = menu.groups.map { group -> String in
			let lower = group.displayName.lowercased()
			if lower.contains("gpt-5.3") { return "5.3" }
			if lower.contains("gpt-5.2") { return "5.2" }
			if lower.contains("gpt-5.1") { return "5.1" }
			return "other"
		}

		XCTAssertEqual(families, ["5.3", "5.3", "5.2", "5.1", "5.1"])
	}
}
