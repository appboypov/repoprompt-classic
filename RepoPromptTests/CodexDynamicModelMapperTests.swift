import XCTest
@testable import RepoPrompt

final class CodexDynamicModelMapperTests: XCTestCase {
	private func makeRemoteModel() -> CodexAppServerClient.RemoteModel {
		CodexAppServerClient.RemoteModel(
			id: "gpt-5.2-codex",
			model: "gpt-5.2-codex",
			displayName: "gpt-5.2-codex",
			description: "Frontier coding model",
			isDefault: true,
			supportedReasoningEfforts: [
				CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "low", description: "Low effort"),
				CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium effort"),
				CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High effort")
			],
			defaultReasoningEffort: "medium"
		)
	}

	func testDynamicModelsExpandByReasoningEffort() {
		let options = CodexDynamicModelMapper.options(from: [makeRemoteModel()])

		let ids = Set(options.map { $0.id })
		XCTAssertEqual(
			ids,
			Set(["gpt-5.2-codex-low", "gpt-5.2-codex-medium", "gpt-5.2-codex-high"])
		)

		let medium = options.first { $0.id == "gpt-5.2-codex-medium" }
		XCTAssertEqual(medium?.displayName, "GPT-5.2 Codex Medium")
		XCTAssertTrue(medium?.isDefault == true)
	}

	func testDynamicGPT55CodexModelsDisplayAsGPT55() {
		let model = CodexAppServerClient.RemoteModel(
			id: "gpt-5.5",
			model: "gpt-5.5",
			displayName: "gpt-5.5",
			description: "GPT-5.5 Codex model",
			isDefault: true,
			supportedReasoningEfforts: [
				CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "medium", description: "Medium"),
				CodexAppServerClient.RemoteReasoningEffort(reasoningEffort: "high", description: "High")
			],
			defaultReasoningEffort: "high"
		)

		let options = CodexDynamicModelMapper.options(from: [model])

		XCTAssertEqual(options.map(\.id), ["gpt-5.5-medium", "gpt-5.5-high"])
		XCTAssertEqual(options.map(\.displayName), ["GPT-5.5 Medium", "GPT-5.5 High"])
		XCTAssertEqual(options.first { $0.id == "gpt-5.5-high" }?.isDefault, true)

		let records = CodexDynamicModelStore.canonicalRecords(from: [model])
		XCTAssertEqual(
			CodexDynamicModelMapper.displayName(forModelID: "gpt-5.5-high", records: records),
			"GPT-5.5 High"
		)
	}

	func testStoreDisplayNameResolvesSynthesizedVariantCaseInsensitively() {
		let suiteName = "CodexDynamicModelMapperTests-\(UUID().uuidString)"
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			XCTFail("Failed to create isolated UserDefaults suite")
			return
		}
		defer {
			defaults.removePersistentDomain(forName: suiteName)
		}

		CodexDynamicModelStore.save([makeRemoteModel()], defaults: defaults)

		let label = CodexDynamicModelStore.displayName(
			forModelID: "GPT-5.2-CODEX-HIGH",
			defaults: defaults
		)
		XCTAssertEqual(label, "GPT-5.2 Codex High")
	}

	func testDisplayNameLookupKeepsReasoningBaseOutOfSynthesizedOptions() {
		let records = CodexDynamicModelStore.canonicalRecords(from: [makeRemoteModel()])

		XCTAssertNil(CodexDynamicModelMapper.displayName(forModelID: "gpt-5.2-codex", records: records))
		XCTAssertEqual(
			CodexDynamicModelMapper.displayName(forModelID: "gpt-5.2-codex-low", records: records),
			"GPT-5.2 Codex Low"
		)
	}

	func testHumanizedDisplayNameHandlesTemplateLikeCharactersWithoutRegexExpansion() {
		let model = CodexAppServerClient.RemoteModel(
			id: "gpt-5.4-codex-%@-$1",
			model: "gpt-5.4-codex-%@-$1",
			displayName: "gpt-5.4-codex-%@-$1",
			description: "Template-like characters should remain literal",
			isDefault: false,
			supportedReasoningEfforts: [],
			defaultReasoningEffort: nil
		)

		let options = CodexDynamicModelMapper.options(from: [model])

		XCTAssertEqual(options.first?.displayName, "GPT-5.4 Codex %@ $1")
	}

	func testCodexModelSpecifierParsesCaseInsensitiveEffortSuffixes() {
		let xhighSpecifier = CodexModelSpecifier(raw: "gpt-5.2-codex-XHIGH")
		XCTAssertEqual(xhighSpecifier.baseModel, "gpt-5.2-codex")
		XCTAssertEqual(xhighSpecifier.reasoningEffort, .xhigh)

		let minimalSpecifier = CodexModelSpecifier(raw: "gpt-5.2-MINIMAL")
		XCTAssertEqual(minimalSpecifier.baseModel, "gpt-5.2")
		XCTAssertEqual(minimalSpecifier.reasoningEffort, .minimal)
	}

	func testCodexModelSpecifierParsesGPT55CodexRawIDAndCLIArgs() {
		let specifier = CodexModelSpecifier(raw: "gpt-5.5-high")

		XCTAssertEqual(specifier.baseModel, "gpt-5.5")
		XCTAssertEqual(specifier.reasoningEffort, .high)
		XCTAssertEqual(specifier.cliModelArgs, ["--model", "gpt-5.5"])
		XCTAssertEqual(specifier.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=high"])

		let args = CodexExecAgentProvider.codexModelCLIArgs(selectedModelString: "gpt-5.5-high")
		XCTAssertEqual(args.modelArgs, ["--model", "gpt-5.5"])
		XCTAssertEqual(args.configArgs, ["-c", "model_reasoning_effort=high"])
	}

	func testCodexModelSpecifierParsesFastServiceTierAndCLIArgs() {
		let specifier = CodexModelSpecifier(raw: "gpt-5.4-fast-high")

		XCTAssertEqual(specifier.baseModel, "gpt-5.4")
		XCTAssertEqual(specifier.serviceTier, "fast")
		XCTAssertEqual(specifier.reasoningEffort, .high)
		XCTAssertEqual(specifier.cliModelArgs, ["--model", "gpt-5.4"])
		XCTAssertEqual(specifier.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=high"])
		XCTAssertEqual(specifier.cliServiceTierConfigArgs, ["-c", "service_tier=fast"])
	}

	func testCodexExecArgsIncludeFastServiceTierConfigAfterExec() {
		let args = CodexExecAgentProvider.codexModelCLIArgs(selectedModelString: "gpt-5.3-codex-fast-high")

		XCTAssertEqual(args.modelArgs, ["--model", "gpt-5.3-codex"])
		XCTAssertEqual(args.configArgs, [
			"-c", "model_reasoning_effort=high",
			"-c", "service_tier=fast"
		])
	}

	func testCodexExecArgsOmitUnsupportedFastServiceTierConfig() {
		let args = CodexExecAgentProvider.codexModelCLIArgs(selectedModelString: "gpt-5.2-fast-high")

		XCTAssertEqual(args.modelArgs, ["--model", "gpt-5.2"])
		XCTAssertEqual(args.configArgs, ["-c", "model_reasoning_effort=high"])
	}
}
