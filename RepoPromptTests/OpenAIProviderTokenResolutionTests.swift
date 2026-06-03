import XCTest
@testable import RepoPrompt

final class OpenAIProviderTokenResolutionTests: XCTestCase {
	func testOpenAICustomResponsesBuildsPlainResponsesRequest() {
		let provider = OpenAIProvider(serviceTier: "priority")
		let message = AIMessage(systemPrompt: "You are terse.", userMessage: "Say pong.")
		let model = AIModel.openaiCustomResponses(name: "summit-alpha")

		let parameters = provider.buildForegroundResponseParameters(
			message,
			model: model,
			maxTokens: provider.resolvedResponseMaxTokens(for: model, override: nil),
			stream: false
		)

		XCTAssertNil(parameters.reasoning)
		XCTAssertNil(parameters.maxOutputTokens)
		XCTAssertNil(parameters.serviceTier)
	}

	func testOpenAICustomReasoningBuildsReasoningResponsesRequest() {
		let provider = OpenAIProvider(serviceTier: "priority")
		let message = AIMessage(systemPrompt: "You are terse.", userMessage: "Say pong.")
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .high)

		let parameters = provider.buildForegroundResponseParameters(
			message,
			model: model,
			maxTokens: provider.resolvedResponseMaxTokens(for: model, override: nil),
			stream: false
		)

		XCTAssertNotNil(parameters.reasoning)
		XCTAssertNil(parameters.maxOutputTokens)
		XCTAssertNil(parameters.serviceTier)
	}

	func testBuiltInResponsesModelStillUsesConfiguredServiceTier() {
		let provider = OpenAIProvider(serviceTier: "priority")
		let parameters = provider.buildForegroundResponseParameters(
			AIMessage(systemPrompt: "", userMessage: "Say pong."),
			model: .gpt5High,
			maxTokens: provider.resolvedResponseMaxTokens(for: .gpt5High, override: nil),
			stream: false
		)

		XCTAssertEqual(parameters.serviceTier, "priority")
	}

	func testOpenAICustomReasoningDoesNotSynthesizeResponsesMaxTokens() {
		let provider = OpenAIProvider()
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .high)

		XCTAssertNil(provider.resolvedResponseMaxTokens(for: model, override: nil))
	}

	func testOpenAICustomResponsesDoesNotSynthesizeResponsesMaxTokens() {
		let provider = OpenAIProvider()
		let model = AIModel.openaiCustomResponses(name: "summit-alpha")

		XCTAssertNil(provider.resolvedResponseMaxTokens(for: model, override: nil))
	}

	func testOpenAICustomReasoningRespectsExplicitResponsesMaxTokens() {
		let provider = OpenAIProvider()
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .high)

		XCTAssertEqual(provider.resolvedResponseMaxTokens(for: model, override: 4_096), 4_096)
	}

	func testOpenAICustomReasoningRespectsConfiguredResponsesMaxTokens() {
		let provider = OpenAIProvider(configuredMaxTokens: 8_192)
		let model = AIModel.openaiCustomReasoning(name: "summit-alpha", effort: .high)

		XCTAssertEqual(provider.resolvedResponseMaxTokens(for: model, override: nil), 8_192)
	}

	func testBuiltInResponsesModelStillReceivesDefaultMaxTokens() {
		let provider = OpenAIProvider()

		XCTAssertEqual(provider.resolvedResponseMaxTokens(for: .gpt5High, override: nil), 128_000)
	}

	@MainActor
	func testLiveOpenAICustomResponsesThroughAIQueriesServiceIfConfigured() async throws {
		let keyManager = KeyManager()
		guard try await keyManager.getAPIKey(for: .openAI) != nil else {
			throw XCTSkip("No stored OpenAI key available through KeyManager.")
		}

		let service = AIQueriesService(keyManager: keyManager)
		let ok = try await service.testModelCompletion(
			model: .openaiCustomResponses(name: "summit-alpha"),
			message: AIMessage(systemPrompt: "Reply with one word.", userMessage: "Reply with exactly: pong"),
			expectedText: "pong"
		)

		XCTAssertTrue(ok)
	}
}
