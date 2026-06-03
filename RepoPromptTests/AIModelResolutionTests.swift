import XCTest
@testable import RepoPrompt

final class AIModelResolutionTests: XCTestCase {
	func testAllModelsAreDiffEditCapable() {
		let raw = AIModel.geminiFlash25.rawValue
		let savedOverride = ModelOverridesSettings.shared.diffOverrides[raw]
		ModelOverridesSettings.shared.setDiffOverride(for: raw, value: false)
		defer {
			ModelOverridesSettings.shared.diffOverrides[raw] = savedOverride
		}

		let models: [AIModel] = [
			.geminiFlash25,
			.gpt54Nano,
			.openrouterCustom(name: "small-model-with-no-heuristic-match"),
			.customProviderUser(name: "custom-model-with-no-config"),
			.openAIServiceTierVariant(base: .gpt54Nano, tier: "flex")
		]

		for model in models {
			XCTAssertTrue(model.isModelCapableOfDiff, "Expected \(model.rawValue) to use diff editing")
		}
	}

	func testResolvesLegacyGeminiAPIModelToGemini31Preview() {
		XCTAssertEqual(
			AIModel.fromModelName("gemini-3-pro-preview"),
			.gemini3p1ProPreview
		)
	}

	func testResolvesLegacyGeminiCLIModelToGemini31Preview() {
		XCTAssertEqual(
			AIModel.fromModelName("gemini_cli_pro-3.0-preview"),
			.geminiCliPro3p1Preview
		)
	}

	func testTrimsWhitespaceWhenResolvingLegacyGeminiModel() {
		XCTAssertEqual(
			AIModel.fromModelName("  gemini-3-pro-preview  "),
			.gemini3p1ProPreview
		)
	}

	func testResolvesZAIModelTurbo() {
		XCTAssertEqual(
			AIModel.fromModelName("glm-5-turbo"),
			.zaiGLM5Turbo
		)
	}

	func testResolvesZAIModel51() {
		XCTAssertEqual(
			AIModel.fromModelName("glm-5.1"),
			.zaiGLM5
		)
	}

	func testResolvesLegacyZAIModel5AliasToGLM5() {
		XCTAssertEqual(
			AIModel.fromModelName("glm-5"),
			.zaiGLM5_0
		)
	}

	func testRemovedGitHubModelRawValuesNoLongerResolve() {
		XCTAssertNil(AIModel.fromModelName("github/gpt-4.1"))
		XCTAssertNil(AIModel.fromModelName("github/gpt-5"))
		XCTAssertNil(AIModel.fromModelName("github/gpt-5-mini"))
		XCTAssertNil(AIModel.fromModelName("github_custom_stale-model"))
	}

	func testAgentCodexGPT54HighRawStillMapsToCodexProviderModel() {
		XCTAssertEqual(
			AgentModel.resolvedModel(forRaw: "gpt-5.4-high", agentKind: .codexExec),
			.gpt54High
		)
		XCTAssertTrue(AgentModelCatalog.isValid(rawModel: "gpt-5.4-high", for: .codexExec))
	}

	func testOpenAIGPT55BaseAndProSlotsResolveWithoutGPT54BaseAliases() {
		XCTAssertEqual(AIModel.gpt54.rawValue, "gpt-5.5")
		XCTAssertEqual(AIModel.gpt54.displayName, "GPT-5.5 Med")
		XCTAssertEqual(AIModel.gpt54Pro.rawValue, "gpt-5.5-pro")
		XCTAssertEqual(AIModel.gpt54Pro.displayName, "GPT-5.5 Pro")
		XCTAssertEqual(AIModel.gpt54Mini.rawValue, "gpt-5.4-mini")

		XCTAssertEqual(AIModel.fromModelName("gpt-5.5"), .gpt54)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-low"), .gpt54Low)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-high"), .gpt54High)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-xhigh"), .gpt54XHigh)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-pro"), .gpt54Pro)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.5-pro-xhigh"), .gpt54ProXHigh)

		XCTAssertNil(AIModel.fromModelName("gpt-5.4"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-low"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-high"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-xhigh"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-pro"))
		XCTAssertNil(AIModel.fromModelName("gpt-5.4-pro-xhigh"))

		XCTAssertNil(AIModel.fromModelName("gpt-5.5-mini"))
		XCTAssertEqual(AIModel.fromModelName("gpt-5.4-mini"), .gpt54Mini)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.4-mini-high"), .gpt54MiniHigh)
		XCTAssertEqual(AIModel.fromModelName("gpt-5.4-nano"), .gpt54Nano)
	}

	func testOpenAICustomReasoningVariantPreservesSummitAlphaModelName() {
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .high)

		XCTAssertEqual(model.modelName, "summit-alpha")
		XCTAssertEqual(model.displayName, "summit-alpha High")
		XCTAssertEqual(model.providerType, .openAI)
		XCTAssertEqual(model.defaultReasoningEffort, "high")
		XCTAssertTrue(model.usesResponsesAPI)
	}

	func testOpenAICustomReasoningRawValueRoundTripsSummitAlpha() {
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .xhigh)

		let resolved = AIModel.fromModelName(model.rawValue)

		XCTAssertEqual(resolved, model)
		XCTAssertEqual(resolved?.modelName, "summit-alpha")
	}

	func testPlainOpenAICustomRemainsChatStyle() {
		let model = AIModel.openaiCustom(name: "summit-alpha")

		XCTAssertEqual(model.modelName, "summit-alpha")
		XCTAssertNil(model.defaultReasoningEffort)
		XCTAssertFalse(model.usesResponsesAPI)
	}

	func testOpenAICustomResponsesVariantPreservesSummitAlphaWithoutReasoning() {
		let model = AIModel.openaiCustomResponses(name: "summit-alpha")

		XCTAssertEqual(model.modelName, "summit-alpha")
		XCTAssertEqual(model.displayName, "summit-alpha")
		XCTAssertEqual(model.providerType, .openAI)
		XCTAssertNil(model.defaultReasoningEffort)
		XCTAssertTrue(model.usesResponsesAPI)
		XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
	}

	func testOpenAICustomResponsesVariantFactoryCreatesBaseAndExpectedEfforts() {
		let variants = AIModel.openAICustomResponsesVariants(for: "  summit-alpha  ")

		XCTAssertEqual(variants.map(\.modelName), Array(repeating: "summit-alpha", count: 5))
		XCTAssertEqual(variants.map(\.defaultReasoningEffort), [nil, "low", "medium", "high", "xhigh"])
		XCTAssertEqual(variants.map(\.rawValue), [
			"openai_custom_responses_summit-alpha",
			"openai_custom_reasoning_low__summit-alpha",
			"openai_custom_reasoning_medium__summit-alpha",
			"openai_custom_reasoning_high__summit-alpha",
			"openai_custom_reasoning_xhigh__summit-alpha"
		])
	}

	func testIdentityPreventsDelimiterCollisionsForCustomProviderModels() {
		let providerDelimiterModel = AIModel.customProvider(
			name: "friendly|provider",
			provider: "custom",
			model: "model"
		)
		let nameDelimiterModel = AIModel.customProvider(
			name: "provider",
			provider: "custom|friendly",
			model: "model"
		)

		XCTAssertNotEqual(providerDelimiterModel, nameDelimiterModel)
		XCTAssertEqual(Set([providerDelimiterModel, nameDelimiterModel]).count, 2)
	}

	func testClaudeCodeIdentityPreservesSpecifierNormalization() {
		let mixedCase = AIModel.claudeCodeModel(specifier: "  Claude-OPUS-4-6:MAX  ")
		let normalized = AIModel.claudeCodeModel(specifier: "claude-opus-4-6:max")

		XCTAssertEqual(mixedCase, normalized)
		XCTAssertEqual(Set([mixedCase, normalized]).count, 1)
	}

	func testOpenAIServiceTierVariantIdentityIncludesBaseModelAndTier() {
		let flex = AIModel.openAIServiceTierVariant(base: .gpt54, tier: "flex")
		let sameFlex = AIModel.openAIServiceTierVariant(base: .gpt54, tier: "flex")
		let priority = AIModel.openAIServiceTierVariant(base: .gpt54, tier: "priority")
		let lowFlex = AIModel.openAIServiceTierVariant(base: .gpt54Low, tier: "flex")

		XCTAssertEqual(flex, sameFlex)
		XCTAssertNotEqual(flex, priority)
		XCTAssertNotEqual(flex, lowFlex)
		XCTAssertEqual(Set([flex, sameFlex, priority, lowFlex]).count, 3)
	}

	func testExistingClaudeCodeRawValuesStillResolve() {
		XCTAssertEqual(AIModel.fromModelName("claude-code"), .claudeCode)
		XCTAssertEqual(AIModel.fromModelName("sonnet"), .claudeCodeSonnet)
		XCTAssertEqual(AIModel.fromModelName("haiku"), .claudeCodeHaiku)
		XCTAssertEqual(AIModel.fromModelName("opus"), .claudeCodeOpus)
	}

	func testPrefixedClaudeCodePinnedModelResolvesWithoutAnthropicConflict() {
		let model = AIModel.fromModelName("claude_code__claude-opus-4-6")

		XCTAssertEqual(model, .claudeCodeModel(specifier: "claude-opus-4-6"))
		XCTAssertEqual(model?.providerType, .claudeCode)
		XCTAssertEqual(model?.displayName, "Claude Code Opus 4.6")
		XCTAssertEqual(model?.modelName, "claude-opus-4-6")
		XCTAssertNil(model?.defaultReasoningEffort)
		XCTAssertEqual(AIModel.fromModelName("claude-opus-4-6"), .claude4Opus)
	}

	func testPrefixedClaudeCodeEffortModelResolves() {
		let model = AIModel.fromModelName("claude_code__claude-opus-4-6:max")

		XCTAssertEqual(model, .claudeCodeModel(specifier: "claude-opus-4-6:max"))
		XCTAssertEqual(model?.displayName, "Claude Code Opus 4.6 Max")
		XCTAssertEqual(model?.modelName, "claude-opus-4-6")
		XCTAssertEqual(model?.defaultReasoningEffort, "max")
	}

	func testPrefixedClaudeCodeOpus47XHighModelResolves() {
		let model = AIModel.fromModelName("claude_code__claude-opus-4-7:xhigh")

		XCTAssertEqual(model, .claudeCodeModel(specifier: "claude-opus-4-7:xhigh"))
		XCTAssertEqual(model?.providerType, .claudeCode)
		XCTAssertEqual(model?.rawValue, "claude_code__claude-opus-4-7:xhigh")
		XCTAssertEqual(model?.displayName, "Claude Code Opus 4.7 XHigh")
		XCTAssertEqual(model?.modelName, "claude-opus-4-7")
		XCTAssertEqual(model?.defaultReasoningEffort, "xhigh")
		XCTAssertNotEqual(AIModel.fromModelName("claude-opus-4-7"), model)
	}

	func testUnprefixedAgentCatalogClaudeEffortRawResolvesToClaudeCodeProvider() throws {
		let raw = "claude-opus-4-5:high"
		let model = try XCTUnwrap(AIModel.fromModelName(raw))

		XCTAssertEqual(model, .claudeCodeModel(specifier: raw))
		XCTAssertEqual(model.providerType, .claudeCode)
		XCTAssertEqual(model.rawValue, "claude_code__claude-opus-4-5:high")
		XCTAssertEqual(model.displayName, "Claude Code Opus 4.5 High")
		XCTAssertEqual(model.modelName, "claude-opus-4-5")
		XCTAssertEqual(model.defaultReasoningEffort, "high")
	}

	func testPrefixedAgentCatalogClaudeEffortRawRoundTrips() throws {
		let model = try XCTUnwrap(AIModel.fromModelName("claude_code__claude-opus-4-5:high"))

		XCTAssertEqual(model, .claudeCodeModel(specifier: "claude-opus-4-5:high"))
		XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
	}

	func testDiscoveryClaudeEffortTargetsResolveToClaudeCodeAIModels() throws {
		let availability = AgentModelCatalog.AvailabilityContext(
			claudeCodeAvailable: true,
			codexAvailable: false,
			geminiAvailable: false,
			openCodeAvailable: false,
			cursorAvailable: false,
			zaiConfigured: false
		)
		let claudeAgent = try XCTUnwrap(
			AgentModelCatalog.discoveryAgents(availability: availability)
				.first { $0.agent == .claudeCode }
		)
		let effortTargets = claudeAgent.models
			.flatMap(\.startTargets)
			.filter { target in
				let specifier = ClaudeModelSpecifier(raw: target.modelRaw)
				return specifier.baseModel != nil && specifier.effortLevel != nil
			}

		XCTAssertTrue(effortTargets.contains { $0.modelRaw == "claude-opus-4-5:high" })
		for target in effortTargets {
			let model = try XCTUnwrap(AIModel.fromModelName(target.modelRaw), "Expected \(target.modelRaw) to resolve")
			XCTAssertEqual(model.providerType, .claudeCode, "Expected \(target.modelRaw) to stay on Claude Code")
			XCTAssertEqual(AIModel.fromModelName(model.rawValue), model, "Expected \(target.modelRaw) to round-trip through prefixed raw")
		}
	}

	func testAgentCatalogClaudeEffortProviderSelectionMapsRuntimeModelAndEffort() throws {
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-opus-4-5:high")),
			ClaudeCodeCLIModelSelection(modelArgument: "claude-opus-4-5", effortLevel: .high)
		)
	}

	func testAgentCatalogClaudeEffortVariantsResolveWhenAdvertised() {
		XCTAssertEqual(
			AIModel.fromModelName("claude-opus-4-5:medium"),
			.claudeCodeModel(specifier: "claude-opus-4-5:medium")
		)
		XCTAssertEqual(
			AIModel.fromModelName("claude-opus-4-5:low"),
			.claudeCodeModel(specifier: "claude-opus-4-5:low")
		)
		XCTAssertEqual(
			AIModel.fromModelName("claude_code__claude-sonnet-4-6:max"),
			.claudeCodeModel(specifier: "claude-sonnet-4-6:max")
		)
	}

	func testClaudeCodeEffortModelValidationAcceptsAdvertisedVariantsAndRejectsInvalidOnes() {
		XCTAssertEqual(
			AIModel.fromModelName("claude_code__claude-opus-4-6:xhigh"),
			.claudeCodeModel(specifier: "claude-opus-4-6:xhigh")
		)
		XCTAssertNil(AIModel.fromModelName("claude_code__claude-opus-4-7:ultra"))
		XCTAssertNil(AIModel.fromModelName("claude_code__claude-opus-4-5-20251101:high"))
		XCTAssertNil(AIModel.fromModelName("claude_code__default:high"))
		XCTAssertNil(AIModel.fromModelName("claude-opus-4-5-20251101:high"))
		XCTAssertNil(AIModel.fromModelName("default:high"))
		XCTAssertNil(AIModel.fromModelName("claude-opus-4-7:ultra"))
	}

	func testClaudeCodeProviderModelSelectionMapsRuntimeModelAndEffort() throws {
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCode),
			ClaudeCodeCLIModelSelection(modelArgument: nil, effortLevel: nil)
		)
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeOpus),
			ClaudeCodeCLIModelSelection(modelArgument: "opus", effortLevel: nil)
		)
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "opus[1m]:max")),
			ClaudeCodeCLIModelSelection(modelArgument: "opus[1m]", effortLevel: .max)
		)
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-sonnet-4-6:high")),
			ClaudeCodeCLIModelSelection(modelArgument: "claude-sonnet-4-6", effortLevel: .high)
		)
		XCTAssertEqual(
			try ClaudeCodeProvider.resolveCLIModelSelection(for: .claudeCodeModel(specifier: "claude-opus-4-7:xhigh")),
			ClaudeCodeCLIModelSelection(modelArgument: "claude-opus-4-7", effortLevel: .xhigh)
		)
	}
}
