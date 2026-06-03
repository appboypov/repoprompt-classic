import Foundation

final class ZAIProvider: OpenAIProvider {
	init(apiKey: String) {
		let baseURL = URL(string: "https://api.z.ai/api/coding/paas")!
		super.init(
			apiKey: apiKey,
			baseURL: baseURL,
			configuredMaxTokens: nil,
			overrideVersion: "v4"
		)
	}
	
	override func testAPIKey(model: AIModel = .zaiGLM45) async throws -> Bool {
		let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
		do {
			let stream = try await streamMessage(testMessage, model: model)
			var response = ""
			
			for try await result in stream {
				if let text = result.text {
					response += text
				}
				if result.type == "message_stop" {
					break
				}
			}
			
			return response.lowercased().contains("hello")
		} catch {
			print("Z.AI API Key Test Failed: \(error.asFriendlyString())")
			return false
		}
	}
}
