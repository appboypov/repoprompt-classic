import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class AIModelSortingTests: XCTestCase {
	private let codexDynamicModelStoreKey = "CodexDynamicModelRecords"

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

	func testDiffFallbackPrioritiesPreferCodexGPT55BeforeOlderCandidates() {
		let available: [AIModel] = [
			.gpt54High,
			.codexCliGpt5High,
			.codexCliGpt55CodexHigh,
			.codexCliGpt55CodexMedium,
			.codexCliGpt55CodexLow
		]

		XCTAssertEqual(
			AIModel.findBestAvailableModel(in: available, desiredFormat: .diff, priorities: AIModel.highDiffPriority),
			.codexCliGpt55CodexHigh
		)
		XCTAssertEqual(
			AIModel.findBestAvailableModel(in: available, desiredFormat: .diff, priorities: AIModel.mediumDiffPriority),
			.codexCliGpt55CodexHigh
		)
		XCTAssertEqual(
			AIModel.findBestAvailableModel(in: available, desiredFormat: .diff, priorities: AIModel.simpleDiffPriority),
			.codexCliGpt55CodexMedium
		)
	}

	func testSortedForPickerUsesDynamicOpenCodeRawIDsInsteadOfACPDisplayNames() {
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

		let zeta = AIModel.openCodeCustom(name: "zeta-model")
		let alpha = AIModel.openCodeCustom(name: "alpha-model")
		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(rawValue: zeta.modelName, displayName: "AAA should not sort first", description: nil, isDefault: false),
					AgentModelOption(rawValue: alpha.modelName, displayName: "ZZZ should not sort last", description: nil, isDefault: false)
				],
				currentModelRaw: nil
			),
			for: .openCode
		))

		XCTAssertEqual(zeta.displayName, "AAA should not sort first")
		XCTAssertEqual(alpha.displayName, "ZZZ should not sort last")
		XCTAssertEqual(
			AIModel.sortedForPicker([zeta, alpha]).map(\.modelName),
			["alpha-model", "zeta-model"]
		)
	}

	func testSortedForPickerUsesDynamicCursorRawIDsInsteadOfACPDisplayNames() {
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }

		let zeta = AIModel.cursorCustom(name: "zeta-model")
		let alpha = AIModel.cursorCustom(name: "alpha-model")
		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(rawValue: zeta.modelName, displayName: "AAA should not sort first", description: nil, isDefault: false),
					AgentModelOption(rawValue: alpha.modelName, displayName: "ZZZ should not sort last", description: nil, isDefault: false)
				],
				currentModelRaw: nil
			),
			for: .cursor
		))

		XCTAssertEqual(zeta.displayName, "AAA should not sort first")
		XCTAssertEqual(alpha.displayName, "ZZZ should not sort last")
		XCTAssertEqual(
			AIModel.sortedForPicker([zeta, alpha]).map(\.modelName),
			["alpha-model", "zeta-model"]
		)
	}

	func testSortedForPickerUsesDynamicCodexRawIDsInsteadOfStoredDisplayNames() throws {
		try withPreservedCodexDynamicModelStore {
			CodexDynamicModelStore.save([
				CodexAppServerClient.RemoteModel(
					id: "zeta-model",
					model: "zeta-model",
					displayName: "AAA should not sort first",
					description: "",
					isDefault: false,
					supportedReasoningEfforts: [],
					defaultReasoningEffort: nil
				),
				CodexAppServerClient.RemoteModel(
					id: "alpha-model",
					model: "alpha-model",
					displayName: "ZZZ should not sort last",
					description: "",
					isDefault: false,
					supportedReasoningEfforts: [],
					defaultReasoningEffort: nil
				)
			])

			let zeta = AIModel.codexCustom(name: "zeta-model")
			let alpha = AIModel.codexCustom(name: "alpha-model")
			XCTAssertEqual(zeta.displayName, "CLI·Aaa Should Not Sort First")
			XCTAssertEqual(
				AIModel.sortedForPicker([zeta, alpha]).map(\.modelName),
				["alpha-model", "zeta-model"]
			)
		}
	}

	func testSortedForPickerUsesDynamicOpenCodeRawLabelsWhenSemanticMetadataTies() {
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .openCode) }

		let space = AIModel.openCodeCustom(name: "model 1")
		let underscore = AIModel.openCodeCustom(name: "model_1")
		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(rawValue: space.modelName, displayName: "ZZZ High should not sort last", description: nil, isDefault: false),
					AgentModelOption(rawValue: underscore.modelName, displayName: "AAA Low should not sort first", description: nil, isDefault: false)
				],
				currentModelRaw: nil
			),
			for: .openCode
		))

		XCTAssertEqual(space.displayName, "ZZZ High should not sort last")
		XCTAssertEqual(underscore.displayName, "AAA Low should not sort first")
		XCTAssertEqual(
			AIModel.sortedForPicker([underscore, space]).map(\.modelName),
			["model 1", "model_1"]
		)
	}

	func testSortedForPickerUsesDynamicCursorRawLabelsWhenSemanticMetadataTies() {
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
		defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }

		let space = AIModel.cursorCustom(name: "model 1")
		let underscore = AIModel.cursorCustom(name: "model_1")
		XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(rawValue: space.modelName, displayName: "ZZZ High should not sort last", description: nil, isDefault: false),
					AgentModelOption(rawValue: underscore.modelName, displayName: "AAA Low should not sort first", description: nil, isDefault: false)
				],
				currentModelRaw: nil
			),
			for: .cursor
		))

		XCTAssertEqual(space.displayName, "ZZZ High should not sort last")
		XCTAssertEqual(underscore.displayName, "AAA Low should not sort first")
		XCTAssertEqual(
			AIModel.sortedForPicker([underscore, space]).map(\.modelName),
			["model 1", "model_1"]
		)
	}

	func testSortedForPickerUsesDynamicCodexRawLabelsWhenSemanticMetadataTies() throws {
		try withPreservedCodexDynamicModelStore {
			CodexDynamicModelStore.save([
				CodexAppServerClient.RemoteModel(
					id: "model 1",
					model: "model 1",
					displayName: "ZZZ High should not sort last",
					description: "",
					isDefault: false,
					supportedReasoningEfforts: [],
					defaultReasoningEffort: nil
				),
				CodexAppServerClient.RemoteModel(
					id: "model_1",
					model: "model_1",
					displayName: "AAA Low should not sort first",
					description: "",
					isDefault: false,
					supportedReasoningEfforts: [],
					defaultReasoningEffort: nil
				)
			])

			let space = AIModel.codexCustom(name: "model 1")
			let underscore = AIModel.codexCustom(name: "model_1")
			XCTAssertEqual(space.displayName, "CLI·Zzz High Should Not Sort Last")
			XCTAssertEqual(underscore.displayName, "CLI·Aaa Low Should Not Sort First")
			XCTAssertEqual(
				AIModel.sortedForPicker([underscore, space]).map(\.modelName),
				["model 1", "model_1"]
			)
		}
	}

	func testPickerSortComparatorUsesTransitiveSemanticOrdering() {
		let newerFoo = AIModel.customProvider(name: "z", provider: "p", model: "foo-2")
		let olderFoo = AIModel.customProvider(name: "a", provider: "p", model: "foo-1")
		let bar = AIModel.customProvider(name: "m", provider: "p", model: "bar")

		let sorted = AIModel.sortedForPicker([newerFoo, olderFoo, bar])

		XCTAssertEqual(sorted.map(\.modelName), ["bar", "foo-2", "foo-1"])
		XCTAssertTrue(AIModel.pickerSortComparator(newerFoo, olderFoo))
		XCTAssertFalse(AIModel.pickerSortComparator(olderFoo, bar))
		XCTAssertFalse(AIModel.pickerSortComparator(bar, bar))
	}

	func testSortedForPickerOrdersNewerCodexBaseVersionsFirst() {
		let models: [AIModel] = [
			.codexCustom(name: "gpt-5.3-codex-high"),
			.codexCustom(name: "gpt-5.5-high"),
			.codexCustom(name: "gpt-5.4-high"),
			.codexCustom(name: "gpt-5.2-medium")
		]

		let sorted = AIModel.sortedForPicker(models)

		XCTAssertEqual(
			sorted.map(\.modelName),
			["gpt-5.5-high", "gpt-5.4-high", "gpt-5.3-codex-high", "gpt-5.2-medium"]
		)
	}

	func testSortedForPickerPreservesCodexReasoningAndTierOrder() {
		let models: [AIModel] = [
			.codexCustom(name: "gpt-5.3-xhigh"),
			.codexCustom(name: "gpt-5.4-high"),
			.codexCustom(name: "gpt-5.4-fast-low"),
			.codexCustom(name: "gpt-5.4-low"),
			.codexCustom(name: "gpt-5.4")
		]

		let sorted = AIModel.sortedForPicker(models)

		XCTAssertEqual(
			sorted.map(\.modelName),
			["gpt-5.4", "gpt-5.4-low", "gpt-5.4-fast-low", "gpt-5.4-high", "gpt-5.3-xhigh"]
		)
	}

	func testCodexMenuGroupsNestReasoningLevelsUnderNewestBaseModelFirst() {
		let models: [AIModel] = [
			.codexCustom(name: "gpt-5.3-medium"),
			.codexCustom(name: "gpt-5.5-medium"),
			.codexCustom(name: "gpt-5.4-high"),
			.codexCustom(name: "gpt-5.4-low"),
			.codexCustom(name: "gpt-5.2-medium")
		]

		let groups = AIModel.codexMenuGroups(for: models)

		XCTAssertEqual(groups.map(\.displayName), ["GPT-5.5", "GPT-5.4", "GPT-5.3", "GPT-5.2"])
		XCTAssertEqual(groups.first?.models.map(\.modelName), ["gpt-5.5-medium"])
	}

	func testCodexMenuGroupsPlaceBaseModelAheadOfReasoningVariants() {
		let models: [AIModel] = [
			.codexCustom(name: "gpt-5.4-codex-high"),
			.codexCustom(name: "gpt-5.4-codex"),
			.codexCustom(name: "gpt-5.4-codex-low")
		]

		let groups = AIModel.codexMenuGroups(for: models)

		XCTAssertEqual(groups.first?.displayName, "GPT-5.4 Codex")
		XCTAssertEqual(
			groups.first?.models.map(\.modelName),
			["gpt-5.4-codex", "gpt-5.4-codex-low", "gpt-5.4-codex-high"]
		)
	}

	func testAgentModelCatalogCodexMenuOrdersBaseModelsSemantically() {
		let options = [
			AgentModelOption(rawValue: "gpt-5.3-codex-high", displayName: "GPT-5.3 Codex High", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.5-high", displayName: "GPT-5.5 High", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.4-high", displayName: "GPT-5.4 High", description: nil, isDefault: false),
			AgentModelOption(rawValue: "gpt-5.2-medium", displayName: "GPT-5.2 Medium", description: nil, isDefault: false)
		]

		let menu = AgentModelCatalog.codexMenu(for: options)

		XCTAssertEqual(menu.groups.map(\.displayName), ["GPT-5.5", "GPT-5.4", "GPT-5.3 Codex", "GPT-5.2"])
	}

	func testParsesOpenAIGPT55AndCodexRecommendationModels() {
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-pro"), .gpt54Pro)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-pro-xhigh"), .gpt54ProXHigh)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5"), .gpt54)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-high"), .gpt54High)
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-pro"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-pro-xhigh"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.5-mini"))
		XCTAssertEqual(AIModel.fromModelName("gpt-5.4-mini"), .gpt54Mini)

		let openAIRawValues = Set(AIModel.modelsForProvider(.openAI).map(\.rawValue))
		XCTAssertTrue(openAIRawValues.contains("gpt-5.5"))
		XCTAssertTrue(openAIRawValues.contains("gpt-5.5-pro"))
		XCTAssertFalse(openAIRawValues.contains("gpt-5.4"))
		XCTAssertFalse(openAIRawValues.contains("gpt-5.4-pro"))
		XCTAssertTrue(openAIRawValues.contains("gpt-5.4-mini"))
		XCTAssertTrue(openAIRawValues.contains("gpt-5.4-nano"))

		XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.4-high"), .codexCliGpt54High)
		XCTAssertEqual(AIModel.fromModelName("codex_cli_gpt-5.5-high"), .codexCliGpt55CodexHigh)
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.4-medium", agentKind: .codexExec), .gpt54Medium)
		XCTAssertEqual(AgentModel.resolvedModel(forRaw: "gpt-5.5-high", agentKind: .codexExec), .gpt55CodexHigh)
		XCTAssertEqual(AgentModelCatalog.displayName(for: "gpt-5.5-high", agentKind: .codexExec, codexDynamicModels: []), "GPT-5.5 High")
	}

	func testClaudeCodeProviderModelsIncludePinnedModelsAndSupportedEfforts() {
		let rawValues = Set(AIModel.modelsForProvider(.claudeCode).map(\.rawValue))

		XCTAssertTrue(rawValues.contains("claude-code"))
		XCTAssertTrue(rawValues.contains("opus"))
		XCTAssertTrue(rawValues.contains("claude_code__opus[1m]"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-opus-4-7"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-opus-4-7:xhigh"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-opus-4-6"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-opus-4-6:max"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-opus-4-5-20251101"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-sonnet-4-6:high"))
		XCTAssertTrue(rawValues.contains("claude_code__claude-haiku-4-5-20251001"))
		XCTAssertFalse(rawValues.contains("claude_code__claude-sonnet-4-6:max"))
		XCTAssertFalse(rawValues.contains("claude_code__claude-opus-4-6:xhigh"))
	}

	func testClaudeCodeMenuGroupsModelsAndSupportedEfforts() {
		let menu = AIModel.claudeCodeMenu(for: AIModel.modelsForProvider(.claudeCode))

		XCTAssertNil(menu.defaultOption)
		XCTAssertEqual(Array(menu.groups.prefix(5)).map(\.displayName), [
			"Opus Latest (1M)",
			"Opus Latest",
			"Opus 4.7",
			"Opus 4.6",
			"Opus 4.5"
		])
		let opus47 = menu.groups.first { $0.displayName == "Opus 4.7" }
		XCTAssertEqual(opus47?.rendersAsSubmenu, true)
		XCTAssertEqual(opus47?.options.map(\.displayName), ["Low", "Medium", "High", "XHigh"])
		let opus46 = menu.groups.first { $0.displayName == "Opus 4.6" }
		XCTAssertEqual(opus46?.rendersAsSubmenu, true)
		XCTAssertEqual(opus46?.options.map(\.displayName), ["Low", "Medium", "High", "Max"])
		let sonnet46 = menu.groups.first { $0.displayName == "Sonnet 4.6" }
		XCTAssertEqual(sonnet46?.rendersAsSubmenu, true)
		XCTAssertEqual(sonnet46?.options.map(\.displayName), ["Low", "Medium", "High"])
		let opus45 = menu.groups.first { $0.displayName == "Opus 4.5" }
		XCTAssertEqual(opus45?.rendersAsSubmenu, false)
		XCTAssertEqual(opus45?.options.map(\.displayName), ["Opus 4.5"])
	}
}
