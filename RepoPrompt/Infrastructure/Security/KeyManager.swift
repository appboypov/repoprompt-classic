import Foundation

actor KeyManager {
	private let secureService: SecureKeysService
	
	// Simple in-memory store of keys
	private var cache = [AIProviderType: String]()
	
	init(secureService: SecureKeysService = SecureKeysService()) {
		self.secureService = secureService
	}
	
	/// Lazily loads the key from disk only if not already in the `cache`.
	func getAPIKey(for provider: AIProviderType) async throws -> String? {
		if let cached = cache[provider] {
			return cached
		}
		
		let identifier = provider.secureIdentifier
		let keyFromDisk = try await secureService.getAPIKey(for: identifier)
		
		if let k = keyFromDisk {
			cache[provider] = k
		}
		
		return keyFromDisk
	}
	
	/// Saves to both in-memory cache and disk.
	func saveAPIKey(_ key: String, for provider: AIProviderType) throws {
		cache[provider] = key
		let identifier = provider.secureIdentifier
		try secureService.saveAPIKey(key, for: identifier)
	}
	
	/// Deletes from both in-memory cache and disk.
	func deleteAPIKey(for provider: AIProviderType) throws {
		cache.removeValue(forKey: provider)
		let identifier = provider.secureIdentifier
		try secureService.deleteAPIKey(for: identifier)
	}
}

extension AIProviderType {
	/// Maps each `AIProviderType` to the secureIdentifier used by `SecureKeysService`.
	var secureIdentifier: String {
		switch self {
		case .anthropic:       return "AnthropicAPI"
		case .openAI:          return "OpenAIAPI"
		case .gemini:          return "GeminiAPI"
		case .openRouter:      return "OpenRouterAPI"
		case .ollama:          return "OllamaURL"
		case .azure:           return "AzureAPI"
		case .deepseek:        return "DeepSeekAPI"
		case .customProvider:  return "CustomProviderAPI"
		case .fireworks:       return "FireworksAPI" // Add Fireworks case
		case .grok:            return "GrokAPI"      // Add Grok case
		case .groq:            return "GroqAPI"      // Add Groq case
		case .claudeCode:      return "ClaudeCodeAPI" // Add Claude Code case
		case .codex:          return "CodexCLIAPI"
		case .geminiCli:       return "GeminiCLIAPI"
		case .openCode:        return "OpenCodeCLIAPI"
		case .cursor:          return "CursorCLIAPI"
		case .zAI:             return "ZAIAPI"
		}
	}
}
