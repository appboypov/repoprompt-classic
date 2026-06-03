import SwiftOpenAI
import SwiftAnthropic
import Foundation

enum ModelPickerStringOrdering {
	static func compare(
		_ lhs: String,
		_ rhs: String,
		caseInsensitiveASCII: Bool
	) -> ComparisonResult {
		let foldedComparison = compareScalars(
			lhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) },
			rhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) }
		)
		if foldedComparison != .orderedSame || !caseInsensitiveASCII {
			return foldedComparison
		}

		return compareScalars(
			lhs.unicodeScalars.map(\.value),
			rhs.unicodeScalars.map(\.value)
		)
	}

	static func precedes(
		_ lhs: String,
		_ rhs: String,
		caseInsensitiveASCII: Bool = true
	) -> Bool {
		compare(lhs, rhs, caseInsensitiveASCII: caseInsensitiveASCII) == .orderedAscending
	}

	private static func foldedScalarValue(
		_ value: UInt32,
		caseInsensitiveASCII: Bool
	) -> UInt32 {
		guard caseInsensitiveASCII, value >= 65, value <= 90 else { return value }
		return value + 32
	}

	private static func compareScalars(
		_ lhs: [UInt32],
		_ rhs: [UInt32]
	) -> ComparisonResult {
		let count = min(lhs.count, rhs.count)
		for index in 0..<count {
			if lhs[index] == rhs[index] { continue }
			return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
		}
		if lhs.count == rhs.count { return .orderedSame }
		return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
	}
}

public enum AIModel: Equatable, Hashable {
	// OpenAI Models
	case gpt41

	// Service tier variant wrapper (for OpenAI Responses API models)
	indirect case openAIServiceTierVariant(base: AIModel, tier: String)

	case gpt5
	case gpt5Low
	case gpt5High
	case gpt5XHigh
	// Internal gpt54* case names are retained for source compatibility; the
	// OpenAI API base/pro slots below now point at GPT-5.5. Mini/Nano remain GPT-5.4.
	case gpt54
	case gpt54Low
	case gpt54High
	case gpt54XHigh
	case gpt54Mini
	case gpt54MiniLow
	case gpt54MiniHigh
	case gpt54MiniXHigh
	case gpt54Nano

	case gpt5CodexLow
	case gpt5CodexMed
	case gpt5CodexHigh
	case gpt5CodexXHigh

	// Codex CLI Provider Models
	case codexCliGpt55CodexLow
	case codexCliGpt55CodexMedium
	case codexCliGpt55CodexHigh
	case codexCliGpt55CodexXHigh
	case codexCliGpt5Low
	case codexCliGpt5Medium
	case codexCliGpt5High
	case codexCliGpt5XHigh
	case codexCliGpt54Low
	case codexCliGpt54Medium
	case codexCliGpt54High
	case codexCliGpt54XHigh
	case codexCliGpt5Mini

	case codexCliGpt5CodexLow
	case codexCliGpt5CodexMedium
	case codexCliGpt5CodexHigh
	case codexCliGpt5CodexXHigh
	case codexCliGpt5CodexMini

	// Gemini CLI Provider Models
	case geminiCliFlash25
	case geminiCliPro25
	case geminiCliPro3p1Preview
	case geminiCliFlash3Preview

	case gpt4o
	case o3
	case o1Preview
	case o1Mini
	case gpt5Pro
	case gpt5ProXHigh
	case gpt54Pro
	case gpt54ProXHigh

	// --- NEW o3 variants ---
	case o3Low            // o3-low   – low reasoning effort
	case o3High           // o3-high  – high reasoning effort

	// Anthropic Models
	case claude45Haiku
	case claude4Sonnet
	case claude4SonnetThinking
	case claude4SonnetThinkingMax
	// Add Claude Opus 4.0 and its thinking mode
	case claude4Opus
	case claude4OpusThinking
	
	// Gemini Models
	case geminiFlashLatest
	case gemini2flashlite
	case geminiProLatest
	case geminiFlash2
	case geminiFlash25
	case geminiFlash25LitePreview
	case geminiFlashThinking
	case geminiPro25
	case gemini3p1ProPreview
	case gemini3FlashPreview
	
	// Deepseek Models
	case deepseekChat
	case deepseekReasoner
	
	// Ollama
	case ollama
	
	// OpenRouter Models
	case openrouterDeepseekChat
	case openrouterGpt5
	case openrouterGeminiFlash
	case openrouterGeminiPro
	case openrouterClaude4Sonnet
	case openrouterClaude4Opus

	case openrouterGeminiPro25
	case openrouterCustom(name: String)
	
	// Per-provider user-defined models
	case openaiCustom(name: String)
	case openaiCustomResponses(name: String)
	case openaiCustomReasoning(name: String, effort: CodexReasoningEffort)
	case anthropicCustom(name: String)
	case geminiCustom(name: String)
	case deepseekCustom(name: String)
	case fireworksCustom(name: String)
	case azureCustom(name: String)
	case grokCustom(name: String) // <-- New custom model case for Grok
	case groqCustom(name: String) // <-- New custom model case for Groq
	case zaiCustom(name: String)
	case codexCustom(name: String)
	case openCodeCustom(name: String)
	case cursorCustom(name: String)
	
	// Custom Provider Models
	case customProvider(name: String, provider: String, model: String)
	case customProviderUser(name: String)
	
	// **New Fireworks Models**
	case fireworksDeepseekV3p1Terminus
	case fireworksGLM46
	case fireworksKimiK2Instruct0905
	case fireworksGptOss120b
	case fireworksQwen3235bA22bThinking2507
	case fireworksQwen3Coder480bA35bInstruct
	case fireworksQwen3235bA22bInstruct2507

	// **New Grok Models**
	case grok40709
	case grokCodeFast1
	case grok4FastReasoning
	case grok4FastNonReasoning
	
	// **New Groq Models**
	case groqKimi
	
	// Z.AI Models
	case zaiGLM5
	case zaiGLM5_0
	case zaiGLM5Turbo
	case zaiGLM47
	case zaiGLM47Flash
	case zaiGLM46
	case zaiGLM45
	case zaiGLM45Air
	case zaiGLM45Flash
	
	// Claude Code Models
	case claudeCode
	case claudeCodeSonnet
	case claudeCodeHaiku
	case claudeCodeOpus
	case claudeCodeModel(specifier: String)
	
	
	private struct ProviderIndex {
		static let openAI = 0
		static let anthropic = 1
		static let gemini = 2
		static let openRouter = 3
		static let deepseek = 4
		static let fireworks = 5 // <-- New index for Fireworks
		static let grok = 6      // <-- New index for Grok
		static let groq = 7      // <-- New index for Groq
		static let claudeCode = 8 // <-- New index for Claude Code
		static let zAI = 9
		static let azure = 10
		static let codex = 11
		static let geminiAgent = 12 // <-- New index for Gemini CLI
		static let openCode = 13
		static let cursor = 14
		static let special = -1
	}
	
	private struct ModelInfo {
		let model: AIModel
		let rawValue: String
		let actualName: String?  // Used for providers that may have clashing names
		let displayName: String
		let provider: Int
		var availableFrom: Date? = nil  // Optional release date for staged rollouts
	}

	private static let azureVariantPrefix = "__azure_default__"

	private static func codexModelsForPicker() -> [AIModel] {
		CodexAIModelCatalog.modelsForPicker(staticModels: Array(modelGroups[ProviderIndex.codex]))
	}

	private static func azureVariantKey(for name: String) -> String {
		name.hasPrefix(azureVariantPrefix) ? name : "\(azureVariantPrefix)\(name)"
	}

	private static func azureVariantBaseName(from name: String) -> String {
		name.hasPrefix(azureVariantPrefix)
			? String(name.dropFirst(azureVariantPrefix.count))
			: name
	}

	private static let openAICustomReasoningEfforts: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh]

	static func openAICustomResponsesVariants(for customModelName: String) -> [AIModel] {
		let baseName = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !baseName.isEmpty else { return [] }
		return [.openaiCustomResponses(name: baseName)]
			+ openAICustomReasoningEfforts.map { .openaiCustomReasoning(name: baseName, effort: $0) }
	}
	
	private static let baseModelDefinitions: [ModelInfo] = [
		// OpenAI Models
		// Legacy 4.x series - hidden from display
		//ModelInfo(model: .gpt41, rawValue: "gpt-4.1", actualName: nil, displayName: "gpt 4.1", provider: ProviderIndex.openAI),
		//ModelInfo(model: .gpt4o, rawValue: "gpt-4o", actualName: nil, displayName: "gpt 4o", provider: ProviderIndex.openAI),

		ModelInfo(model: .gpt5, rawValue: "gpt-5.2", actualName: nil, displayName: "GPT-5.2 Med", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5Low, rawValue: "gpt-5.2-low", actualName: nil, displayName: "GPT-5.2 Low", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5High, rawValue: "gpt-5.2-high", actualName: nil, displayName: "GPT-5.2 High", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5XHigh, rawValue: "gpt-5.2-xhigh", actualName: nil, displayName: "GPT-5.2 XHigh", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54, rawValue: "gpt-5.5", actualName: nil, displayName: "GPT-5.5 Med", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54Low, rawValue: "gpt-5.5-low", actualName: "gpt-5.5", displayName: "GPT-5.5 Low", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54High, rawValue: "gpt-5.5-high", actualName: "gpt-5.5", displayName: "GPT-5.5 High", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54XHigh, rawValue: "gpt-5.5-xhigh", actualName: "gpt-5.5", displayName: "GPT-5.5 XHigh", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54Mini, rawValue: "gpt-5.4-mini", actualName: nil, displayName: "GPT-5.4 Mini", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54MiniLow, rawValue: "gpt-5.4-mini-low", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini Low", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54MiniHigh, rawValue: "gpt-5.4-mini-high", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini High", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54MiniXHigh, rawValue: "gpt-5.4-mini-xhigh", actualName: "gpt-5.4-mini", displayName: "GPT-5.4 Mini XHigh", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54Nano, rawValue: "gpt-5.4-nano", actualName: nil, displayName: "GPT-5.4 Nano", provider: ProviderIndex.openAI),

		ModelInfo(model: .gpt5CodexLow, rawValue: "gpt-5.1-codex-max-low", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max Low", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5CodexMed, rawValue: "gpt-5.1-codex-max", actualName: nil, displayName: "GPT-5.1 Codex Max Med", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5CodexHigh, rawValue: "gpt-5.1-codex-max-high", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max High", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5CodexXHigh, rawValue: "gpt-5.1-codex-max-xhigh", actualName: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max XHigh", provider: ProviderIndex.openAI),

		// O-series models - hidden from display
		//ModelInfo(model: .o3, rawValue: "o3", actualName: nil, displayName: "o3 Med", provider: ProviderIndex.openAI),
		//ModelInfo(model: .o3Low,  rawValue: "o3-low",   actualName: nil, displayName: "o3 low",  provider: ProviderIndex.openAI),
		//ModelInfo(model: .o3High, rawValue: "o3-high",  actualName: nil, displayName: "o3 high", provider: ProviderIndex.openAI),
		//ModelInfo(model: .o1Preview, rawValue: "o1-preview", actualName: nil, displayName: "o1 preview", provider: ProviderIndex.openAI),
		//ModelInfo(model: .o1Mini, rawValue: "o1-mini", actualName: nil, displayName: "o1-mini", provider: ProviderIndex.openAI),
		//ModelInfo(model: .o3pro, rawValue: "o1-pro", actualName: nil, displayName: "o1 pro", provider: ProviderIndex.openAI),

		ModelInfo(model: .gpt5Pro, rawValue: "gpt-5.2-pro", actualName: nil, displayName: "GPT-5.2 Pro", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt5ProXHigh, rawValue: "gpt-5.2-pro-xhigh", actualName: "gpt-5.2-pro", displayName: "GPT-5.2 Pro XHigh", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54Pro, rawValue: "gpt-5.5-pro", actualName: nil, displayName: "GPT-5.5 Pro", provider: ProviderIndex.openAI),
		ModelInfo(model: .gpt54ProXHigh, rawValue: "gpt-5.5-pro-xhigh", actualName: "gpt-5.5-pro", displayName: "GPT-5.5 Pro XHigh", provider: ProviderIndex.openAI),

		// Codex CLI Provider Models
		ModelInfo(model: .codexCliGpt55CodexLow, rawValue: "codex_cli_gpt-5.5-low", actualName: "gpt-5.5", displayName: "CLI·GPT-5.5 Low", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt55CodexMedium, rawValue: "codex_cli_gpt-5.5-medium", actualName: "gpt-5.5", displayName: "CLI·GPT-5.5 Medium", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt55CodexHigh, rawValue: "codex_cli_gpt-5.5-high", actualName: "gpt-5.5", displayName: "CLI·GPT-5.5 High", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt55CodexXHigh, rawValue: "codex_cli_gpt-5.5-xhigh", actualName: "gpt-5.5", displayName: "CLI·GPT-5.5 XHigh", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5Low, rawValue: "codex_cli_gpt-5.2-low", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 Low", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5Medium, rawValue: "codex_cli_gpt-5.2-medium", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 Medium", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5High, rawValue: "codex_cli_gpt-5.2-high", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 High", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5XHigh, rawValue: "codex_cli_gpt-5.2-xhigh", actualName: "gpt-5.2", displayName: "CLI·GPT-5.2 XHigh", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt54Low, rawValue: "codex_cli_gpt-5.4-low", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 Low", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt54Medium, rawValue: "codex_cli_gpt-5.4-medium", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 Medium", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt54High, rawValue: "codex_cli_gpt-5.4-high", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 High", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt54XHigh, rawValue: "codex_cli_gpt-5.4-xhigh", actualName: "gpt-5.4", displayName: "CLI·GPT-5.4 XHigh", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5Mini, rawValue: "codex_cli_gpt-5.1-mini", actualName: "gpt-5.1-mini", displayName: "CLI·GPT-5.1 Mini", provider: ProviderIndex.codex),

		ModelInfo(model: .codexCliGpt5CodexLow, rawValue: "codex_cli_gpt-5.3-codex-low", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex Low", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5CodexMedium, rawValue: "codex_cli_gpt-5.3-codex-medium", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex Medium", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5CodexHigh, rawValue: "codex_cli_gpt-5.3-codex-high", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex High", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5CodexXHigh, rawValue: "codex_cli_gpt-5.3-codex-xhigh", actualName: "gpt-5.3-codex", displayName: "CLI·GPT-5.3 Codex XHigh", provider: ProviderIndex.codex),
		ModelInfo(model: .codexCliGpt5CodexMini, rawValue: "codex_cli_gpt-5.1-codex-mini", actualName: "gpt-5.1-codex-mini", displayName: "CLI·GPT-5.1 Codex Mini", provider: ProviderIndex.codex),

		// Gemini CLI Provider Models
		ModelInfo(model: .geminiCliFlash25, rawValue: "gemini_cli_flash-2.5", actualName: "gemini-2.5-flash", displayName: "CLI·Gemini Flash 2.5", provider: ProviderIndex.geminiAgent),
		ModelInfo(model: .geminiCliPro25, rawValue: "gemini_cli_pro-2.5", actualName: "gemini-2.5-pro", displayName: "CLI·Gemini Pro 2.5", provider: ProviderIndex.geminiAgent),
		ModelInfo(model: .geminiCliPro3p1Preview, rawValue: "gemini_cli_pro-3.1-preview", actualName: "gemini-3.1-pro-preview", displayName: "CLI·Gemini Pro 3.1 Preview", provider: ProviderIndex.geminiAgent),
		// Gemini 3.0 Flash Preview
		ModelInfo(model: .geminiCliFlash3Preview, rawValue: "gemini_cli_flash-3.0-preview", actualName: "gemini-3-flash-preview", displayName: "CLI·Gemini Flash 3.0 Preview", provider: ProviderIndex.geminiAgent),

		// Anthropic Models
		ModelInfo(model: .claude45Haiku, rawValue: "claude-haiku-4-5", actualName: nil, displayName: "Claude Haiku 4.5", provider: ProviderIndex.anthropic),
		ModelInfo(model: .claude4Sonnet, rawValue: "claude-sonnet-4-5-20250929", actualName: nil, displayName: "Claude Sonnet 4.5", provider: ProviderIndex.anthropic),
		ModelInfo(model: .claude4SonnetThinking, rawValue: "claude-sonnet-4-5-20250929-thinking", actualName: nil, displayName: "Claude Sonnet 4.5 Thinking", provider: ProviderIndex.anthropic),
		ModelInfo(model: .claude4SonnetThinkingMax, rawValue: "claude-sonnet-4-5-20250929-thinking-max", actualName: nil, displayName: "Claude Sonnet 4.5 Thinking Max", provider: ProviderIndex.anthropic),
		// Add Claude Opus 4.0 and its thinking mode
		ModelInfo(model: .claude4Opus, rawValue: "claude-opus-4-6", actualName: nil, displayName: "Claude Opus 4.6", provider: ProviderIndex.anthropic),
		ModelInfo(model: .claude4OpusThinking, rawValue: "claude-opus-4-6-thinking", actualName: nil, displayName: "Claude Opus 4.6 Thinking", provider: ProviderIndex.anthropic),
		
		// Gemini Models
		ModelInfo(model: .gemini2flashlite, rawValue: "gemini-2.0-flash-lite", actualName: nil, displayName: "Gemini 2.0 Flash Lite", provider: ProviderIndex.gemini),
		ModelInfo(model: .geminiFlash2, rawValue: "gemini-2.0-flash", actualName: nil, displayName: "Gemini 2.0 Flash", provider: ProviderIndex.gemini),
		ModelInfo(model: .geminiFlash25, rawValue: "gemini-2.5-flash", actualName: nil, displayName: "Gemini 2.5 Flash", provider: ProviderIndex.gemini),
		ModelInfo(model: .geminiFlash25LitePreview, rawValue: "gemini-2.5-flash-lite-preview-06-17", actualName: nil, displayName: "Gemini 2.5 Flash Lite Preview 06-17", provider: ProviderIndex.gemini),
		ModelInfo(model: .geminiPro25, rawValue: "gemini-2.5-pro", actualName: nil, displayName: "Gemini 2.5 Pro", provider: ProviderIndex.gemini),
		ModelInfo(model: .gemini3p1ProPreview, rawValue: "gemini-3.1-pro-preview", actualName: nil, displayName: "Gemini 3.1 Pro Preview", provider: ProviderIndex.gemini),
		// Gemini 3.0 Flash Preview
		ModelInfo(model: .gemini3FlashPreview, rawValue: "gemini-3-flash-preview", actualName: nil, displayName: "Gemini 3.0 Flash Preview", provider: ProviderIndex.gemini),

		// Special Models
		ModelInfo(model: .ollama, rawValue: "Ollama", actualName: nil, displayName: "local/", provider: ProviderIndex.special),
		// OpenRouter Models
		ModelInfo(model: .openrouterDeepseekChat, rawValue: "deepseek/deepseek-chat-v3-0324", actualName: nil, displayName: "oRouter/Deepseek V3 (03-24)", provider: ProviderIndex.openRouter),
		ModelInfo(model: .openrouterGpt5, rawValue: "openai/gpt-5.2", actualName: nil, displayName: "oRouter/GPT-5.2 Med", provider: ProviderIndex.openRouter),
		ModelInfo(model: .openrouterGeminiFlash, rawValue: "google/gemini-2.0-flash-001", actualName: nil, displayName: "oRouter/Gemini Flash 2.0", provider: ProviderIndex.openRouter),
		ModelInfo(model: .openrouterGeminiPro25, rawValue: "google/gemini-2.5-flash-preview", actualName: nil, displayName: "oRouter/Gemini 2.5 Flash Preview", provider: ProviderIndex.openRouter),
		ModelInfo(model: .openrouterClaude4Sonnet, rawValue: "anthropic/claude-sonnet-4.5", actualName: nil, displayName: "oRouter/Claude Sonnet 4.5", provider: ProviderIndex.openRouter),
		ModelInfo(model: .openrouterClaude4Opus, rawValue: "anthropic/claude-opus-4.6", actualName: nil, displayName: "oRouter/Claude Opus 4.6", provider: ProviderIndex.openRouter),
		
		// **New DeepSeek Models**
		ModelInfo(model: .deepseekChat, rawValue: "deepseek-chat", actualName: nil, displayName: "DeepSeek-V3.2-Exp", provider: ProviderIndex.deepseek),
		ModelInfo(model: .deepseekReasoner, rawValue: "deepseek-reasoner", actualName: nil, displayName: "DeepSeek-V3.2-Exp Thinking", provider: ProviderIndex.deepseek),
	
		// **New Fireworks Models**
		ModelInfo(model: .fireworksDeepseekV3p1Terminus, rawValue: "accounts/fireworks/models/deepseek-v3p1-terminus", actualName: nil, displayName: "DeepSeek V3.1 Terminus", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksGLM46, rawValue: "accounts/fireworks/models/glm-4p6", actualName: nil, displayName: "GLM-4.6", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksKimiK2Instruct0905, rawValue: "accounts/fireworks/models/kimi-k2-instruct-0905", actualName: nil, displayName: "Kimi K2 Instruct 0905", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksGptOss120b, rawValue: "accounts/fireworks/models/gpt-oss-120b", actualName: nil, displayName: "OpenAI gpt-oss-120b", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksQwen3235bA22bThinking2507, rawValue: "accounts/fireworks/models/qwen3-235b-a22b-thinking-2507", actualName: nil, displayName: "Qwen3 235B A22B Thinking 2507", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksQwen3Coder480bA35bInstruct, rawValue: "accounts/fireworks/models/qwen3-coder-480b-a35b-instruct", actualName: nil, displayName: "Qwen3 Coder 480B A35B Instruct", provider: ProviderIndex.fireworks),
		ModelInfo(model: .fireworksQwen3235bA22bInstruct2507, rawValue: "accounts/fireworks/models/qwen3-235b-a22b-instruct-2507", actualName: nil, displayName: "Qwen3 235B A22B Instruct 2507", provider: ProviderIndex.fireworks),

		// **New Grok Models**
		ModelInfo(model: .grok40709, rawValue: "grok-4-0709", actualName: nil, displayName: "Grok 4 (0709)", provider: ProviderIndex.grok),
		ModelInfo(model: .grokCodeFast1, rawValue: "grok-code-fast-1", actualName: nil, displayName: "Grok Code Fast 1", provider: ProviderIndex.grok),
		ModelInfo(model: .grok4FastReasoning, rawValue: "grok-4-fast-reasoning", actualName: nil, displayName: "Grok 4 Fast Reasoning", provider: ProviderIndex.grok),
		ModelInfo(model: .grok4FastNonReasoning, rawValue: "grok-4-fast-non-reasoning", actualName: nil, displayName: "Grok 4 Fast", provider: ProviderIndex.grok),
		
		// **New Groq Models**
		ModelInfo(model: .groqKimi, rawValue: "moonshotai/kimi-k2-instruct", actualName: nil, displayName: "groq/Kimi K2", provider: ProviderIndex.groq),
		
		// Z.AI Models
		ModelInfo(model: .zaiGLM5, rawValue: "glm-5.1", actualName: nil, displayName: "Z.AI GLM-5.1", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM5_0, rawValue: "glm-5", actualName: nil, displayName: "Z.AI GLM-5", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM5Turbo, rawValue: "glm-5-turbo", actualName: nil, displayName: "Z.AI GLM-5-Turbo", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM47, rawValue: "glm-4.7", actualName: nil, displayName: "Z.AI GLM-4.7", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM47Flash, rawValue: "glm-4.7-flash", actualName: nil, displayName: "Z.AI GLM-4.7 Flash", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM46, rawValue: "glm-4.6", actualName: nil, displayName: "Z.AI GLM-4.6", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM45, rawValue: "glm-4.5", actualName: nil, displayName: "Z.AI GLM-4.5", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM45Air, rawValue: "glm-4.5-air", actualName: nil, displayName: "Z.AI GLM-4.5 Air", provider: ProviderIndex.zAI),
		ModelInfo(model: .zaiGLM45Flash, rawValue: "glm-4.5-flash", actualName: nil, displayName: "Z.AI GLM-4.5 Flash", provider: ProviderIndex.zAI),
		
		// Claude Code Models
		ModelInfo(model: .claudeCode, rawValue: "claude-code", actualName: nil, displayName: "Claude Code", provider: ProviderIndex.claudeCode),
		ModelInfo(model: .claudeCodeSonnet, rawValue: "sonnet", actualName: nil, displayName: "Claude Code Sonnet Latest", provider: ProviderIndex.claudeCode),
		ModelInfo(model: .claudeCodeHaiku, rawValue: "haiku", actualName: nil, displayName: "Claude Code Haiku Latest", provider: ProviderIndex.claudeCode),
		ModelInfo(model: .claudeCodeOpus, rawValue: "opus", actualName: nil, displayName: "Claude Code Opus Latest", provider: ProviderIndex.claudeCode)
	]

	private static let modelDefinitions: [ModelInfo] = {
		let azureVariants = baseModelDefinitions
			.filter { $0.provider == ProviderIndex.openAI }
			.map { info -> ModelInfo in
				let displaySource = info.displayName.isEmpty ? info.rawValue : info.displayName
				return ModelInfo(
					model: .azureCustom(name: azureVariantKey(for: info.rawValue)),
					rawValue: "azure_custom_\(info.rawValue)",
					actualName: nil,
					displayName: "azure/\(displaySource)",
					provider: ProviderIndex.azure
				)
			}
		return baseModelDefinitions + azureVariants
	}()
	
	private static let modelData: [AIModel: (rawValue: String, displayName: String)] = {
		let pairs = modelDefinitions.map { info in
			(info.model, (rawValue: info.rawValue, displayName: info.displayName))
		}
		var seen: Set<AIModel> = []
		var duplicates: [AIModel] = []
		for (model, _) in pairs {
			if !seen.insert(model).inserted {
				duplicates.append(model)
			}
		}
		#if DEBUG
		if !duplicates.isEmpty {
			print("AIModel.modelData duplicate keys: \(duplicates)")
		}
		#endif
		return Dictionary(pairs, uniquingKeysWith: { existing, _ in existing })
	}()
	
	private static let modelGroups: [Set<AIModel>] = {
		var groups: [Set<AIModel>] = Array(repeating: [], count: 15) // Includes CLI provider groups through Cursor
		for info in modelDefinitions where info.provider >= 0 {
			groups[info.provider].insert(info.model)
		}
		return groups
	}()


	// MARK: - Service Tier Variant Helpers
	private static let openAITierPrefix = "openai_tier__"

	/// Returns the service tier override if this is a tier variant, nil otherwise
	var openAIServiceTierOverride: String? {
		if case .openAIServiceTierVariant(_, let tier) = self { return tier }
		return nil
	}

	/// Returns the base model (unwraps tier variant if applicable)
	var openAIServiceTierBase: AIModel {
		if case .openAIServiceTierVariant(let base, _) = self { return base }
		return self
	}

	/// Returns true if this is a service tier variant
	var isOpenAIServiceTierVariant: Bool {
		if case .openAIServiceTierVariant = self { return true }
		return false
	}

	private var openAITierDisplayName: String {
		switch openAIServiceTierOverride {
		case "default": return "Default"
		case "flex": return "Flex"
		case "priority": return "Priority"
		case "auto": return "Auto"
		default: return (openAIServiceTierOverride ?? "").capitalized
		}
	}
	
	var rawValue: String {
		switch self {
		case .openAIServiceTierVariant(let base, let tier):
			return "\(Self.openAITierPrefix)\(tier)__\(base.rawValue)"
		case .openrouterCustom(let name):
			return "openrouter_custom_\(name)"
		case .openaiCustom(let n):
			return "openai_custom_\(n)"
		case .openaiCustomResponses(let n):
			return "openai_custom_responses_\(n)"
		case .openaiCustomReasoning(let n, let effort):
			return "openai_custom_reasoning_\(effort.rawValue)__\(n)"
		case .claudeCodeModel(let specifier):
			return "\(ClaudeCodeAIModelCatalog.rawPrefix)\(ClaudeCodeAIModelCatalog.normalizedSpecifier(specifier))"
		case .anthropicCustom(let n):
			return "anthropic_custom_\(n)"
		case .geminiCustom(let n):
			return "gemini_custom_\(n)"
		case .deepseekCustom(let n):
			return "deepseek_custom_\(n)"
		case .fireworksCustom(let n):
			return "fireworks_custom_\(n)"
		case .azureCustom(let n):
			return "azure_custom_\(n)"
		case .grokCustom(let n): // <-- Handle Grok custom model rawValue
			return "grok_custom_\(n)"
		case .groqCustom(let n): // <-- Handle Groq custom model rawValue
			return "groq_custom_\(n)"
		case .zaiCustom(let n):
			return "zai_custom_\(n)"
		case .codexCustom(let n):
			return "codex_custom_\(n)"
		case .openCodeCustom(let n):
			return "opencode_custom_\(n)"
		case .cursorCustom(let n):
			return "cursor_custom_\(n)"
		case .customProvider( _, _, let model):
			return "custom_provider_\(model)"
		case .customProviderUser(let name):
			return "custom_provider_user_\(name)"
		case .ollama:
			return "ollama_\(modelName)"
		default:
			if let info = Self.modelDefinitions.first(where: { $0.model == self }) {
				return info.rawValue
			}
			return "unknown_model"
		}
	}

	var displayName: String {
		if case .openAIServiceTierVariant(let base, _) = self {
			return "\(base.displayName) (\(openAITierDisplayName))"
		}
		if case .openrouterCustom(let name) = self { return "oRouter/\(name)" }
		if case .openaiCustom(let n) = self { return "\(n)" }
		if case .openaiCustomResponses(let n) = self { return "\(n)" }
		if case .openaiCustomReasoning(let n, let effort) = self { return "\(n) \(effort.displayName)" }
		if case .claudeCodeModel(let specifier) = self { return ClaudeCodeAIModelCatalog.displayName(for: specifier) }
		if case .anthropicCustom(let n) = self { return "\(n)" }
		if case .geminiCustom(let n) = self { return "\(n)" }
		if case .deepseekCustom(let n) = self { return "\(n)" }
		if case .fireworksCustom(let n) = self { return "\(n)" }
		if case .azureCustom(let n) = self {
			if let info = Self.modelData[self] {
				return info.displayName
			}
			let variantKey = Self.azureVariantKey(for: n)
			if let info = Self.modelData[.azureCustom(name: variantKey)] {
				return info.displayName
			}
			let baseName = Self.azureVariantBaseName(from: n)
			return "azure/\(baseName)"
		}
		if case .grokCustom(let n) = self { return "Grok/\(n)" } // <-- Handle Grok custom model displayName
		if case .groqCustom(let n) = self { return "Groq/\(n)" } // <-- Handle Groq custom model displayName
		if case .zaiCustom(let n) = self { return "Z.AI/\(n)" }
		if case .codexCustom(let n) = self {
			if let label = CodexDynamicModelStore.displayName(forModelID: n) {
				return "CLI·\(label)"
			}
			// Humanize the ID for synthesized models not in the store (e.g. fast-tier variants)
			return "CLI·\(Self.humanizedCodexBaseModel(n))"
		}
		if case .openCodeCustom(let n) = self {
			if let option = ACPAIModelCatalog.openCodeModelOption(for: n) {
				return option.displayName
			}
			return n
		}
		if case .cursorCustom(let n) = self {
			if let option = ACPAIModelCatalog.cursorModelOption(for: n) {
				return option.displayName
			}
			let normalized = ACPAIModelCatalog.normalizedCursorModelAlias(n)
			if normalized == AgentModel.cursorAuto.rawValue {
				return AgentModel.cursorAuto.displayName
			}
			if normalized == AgentModel.cursorComposer2.rawValue {
				return AgentModel.cursorComposer2.displayName
			}
			return n
		}
		if case .customProviderUser(let name) = self { return "Custom/\(name)" }
		if case .ollama = self {
			return "local/" + self.modelName
		}
		if case .customProvider(let name, let provider, _) = self {
			return "\(provider)/\(name)"  // Simplified display name
		}
		return Self.modelData[self]?.displayName ?? ""
	}
	
	var provider: AIProvider.Type {
		switch providerType {
		case .openAI:         return OpenAIProvider.self
		case .anthropic:      return AnthropicProvider.self
		case .gemini:         return GeminiProvider.self
		case .azure:          return AzureOpenAIProvider.self
		case .openRouter:     return OpenRouterProvider.self
		case .ollama:         return OpenAIProvider.self          // Ollama uses OpenAI-compatible API
		case .deepseek:       return DeepSeekProvider.self
		case .fireworks:      return FireworksProvider.self
		case .customProvider: return CustomOpenAIProvider.self
		case .grok:           return OpenAIProvider.self // GrokProvider will inherit from OpenAIProvider
		case .groq:           return GroqProvider.self
		case .zAI:            return ZAIProvider.self
		case .claudeCode:     return ClaudeCodeProvider.self
		case .codex:          return CodexCLIProvider.self
		case .geminiCli:      return GeminiCLIProvider.self
		case .openCode:       return OpenCodeCLIProvider.self
		case .cursor:         return CursorCLIProvider.self
		}
	}
	
	var providerType: AIProviderType {
		switch self {
		case .openAIServiceTierVariant(let base, _):
			return base.providerType
			// direct checks for each type
		case .openrouterCustom:
			return .openRouter
		case .customProvider:
			return .customProvider
		case .ollama:
			return .ollama
			
		case .openaiCustom, .openaiCustomResponses, .openaiCustomReasoning:
			return .openAI
		case .anthropicCustom:     return .anthropic
		case .geminiCustom:        return .gemini
		case .deepseekCustom:      return .deepseek
		case .fireworksCustom:     return .fireworks
		case .azureCustom:         return .azure
		case .grokCustom:          return .grok // <-- Handle Grok custom model providerType
		case .groqCustom:          return .groq // <-- Handle Groq custom model providerType
		case .zaiCustom:           return .zAI
		case .claudeCodeModel:     return .claudeCode
		case .codexCustom:         return .codex
		case .openCodeCustom:      return .openCode
		case .cursorCustom:        return .cursor
		case .customProviderUser:  return .customProvider
			
			// or, if you prefer the old modelGroups approach:
		default:
			if Self.modelGroups[ProviderIndex.openAI].contains(self) { return .openAI }
			if Self.modelGroups[ProviderIndex.anthropic].contains(self) { return .anthropic }
			if Self.modelGroups[ProviderIndex.gemini].contains(self) { return .gemini }
			if Self.modelGroups[ProviderIndex.openRouter].contains(self) { return .openRouter }
			if Self.modelGroups[ProviderIndex.deepseek].contains(self) { return .deepseek }
			if Self.modelGroups[ProviderIndex.fireworks].contains(self) { return .fireworks }
			if Self.modelGroups[ProviderIndex.grok].contains(self) { return .grok } // <-- Add Grok to providerType check
			if Self.modelGroups[ProviderIndex.groq].contains(self) { return .groq } // <-- Add Groq to providerType check
			if Self.modelGroups[ProviderIndex.zAI].contains(self) { return .zAI }
			if Self.modelGroups[ProviderIndex.claudeCode].contains(self) { return .claudeCode } // <-- Add Claude Code to providerType check
			if Self.modelGroups[ProviderIndex.codex].contains(self) { return .codex }
			if Self.modelGroups[ProviderIndex.geminiAgent].contains(self) { return .geminiCli }
			if Self.modelGroups[ProviderIndex.openCode].contains(self) { return .openCode }
			if Self.modelGroups[ProviderIndex.cursor].contains(self) { return .cursor }
			// fallback
			return .azure
		}
	}
	
	var claudeCodeRuntimeSpecifierRaw: String? {
		ClaudeCodeAIModelCatalog.runtimeSpecifierRaw(for: self)
	}

	var modelName: String {
		switch self {
		case .openAIServiceTierVariant(let base, _):
			return base.modelName
		case .ollama:
			return UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.1"
		case .openrouterCustom(let name):
			return name
		case .openaiCustom(let n):
			return n
		case .openaiCustomResponses(let n):
			return n
		case .openaiCustomReasoning(let n, _):
			return n
		case .claudeCodeModel(let specifier):
			return ClaudeModelSpecifier(raw: specifier).runtimeModelParam ?? ""
		case .anthropicCustom(let n),
			.geminiCustom(let n),
			.deepseekCustom(let n),
			.fireworksCustom(let n):
			return n
		case .azureCustom(let n):
			return Self.azureVariantBaseName(from: n)
		case .grokCustom(let n),
			.groqCustom(let n),
			.zaiCustom(let n),
			.codexCustom(let n),
			.openCodeCustom(let n),
			.cursorCustom(let n):
			return n
		case .customProviderUser(let name):
			return name
		case .customProvider(_, _, let model):
			return model
		default:
			if let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }) {
				return modelInfo.actualName ?? modelInfo.rawValue
			}
			return self.rawValue
		}
	}
	
	// ==========================================================
	// DIFF PRIORITY ARRAYS
	// ==========================================================

	/// "Simple" diff (cheaper first).
	static let simpleDiffPriority: [AIModel] = [
		// Prioritize practical current CLI variants first
		.claudeCodeSonnet,
		.codexCliGpt55CodexMedium,
		.codexCliGpt55CodexLow,
		.codexCliGpt55CodexHigh,
		.gpt54Low,
		.gpt54,
		.gpt54High,
		.gpt5CodexLow,
		.gpt5Low,
		.gpt41,
		.fireworksDeepseekV3p1Terminus,
		.deepseekChat, .openrouterDeepseekChat,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.gemini3p1ProPreview,
		.geminiPro25, .openrouterGeminiPro25,
		.deepseekReasoner,
		.grok40709, // Add new Grok 4 model
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
	]

	/// "Medium" diff (user's final ranking).
	static let mediumDiffPriority: [AIModel] = [
		// Prioritize practical current CLI variants first
		.claudeCodeSonnet,
		.codexCliGpt55CodexHigh,
		.codexCliGpt55CodexMedium,
		.codexCliGpt55CodexLow,
		.gpt54,
		.gpt54High,
		.gpt54Low,
		.gpt5CodexLow,
		.gpt5Low,
		.gpt41,
		.fireworksDeepseekV3p1Terminus,
		.deepseekChat, .openrouterDeepseekChat,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.gemini3p1ProPreview,
		.geminiPro25, .openrouterGeminiPro25,
		.deepseekReasoner,
		.grok40709, // Add new Grok 4 model
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
	]

	/// "High" diff (top-tier first).
	static let highDiffPriority: [AIModel] = [
		// Then other top models
		.claudeCodeSonnet,
		.codexCliGpt55CodexHigh,
		.codexCliGpt55CodexXHigh,
		.codexCliGpt55CodexMedium,
		.gpt54High,
		.gpt54,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.gpt5CodexLow,
		.gpt5Low,
		.deepseekChat, .openrouterDeepseekChat,
		.fireworksDeepseekV3p1Terminus,
		.gemini3p1ProPreview,
		.geminiPro25, .openrouterGeminiPro25,
		.gpt41,
		.deepseekReasoner,
		.grok40709, // Add new Grok 4 model
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash
	]
	
	// ==========================================================
	// WHOLE ARRAYS
	// ==========================================================

	/// "Simple" whole: prefer current Gemini 3.0 Flash, then fast GPT and fallback models.
	static let simpleWholePriority: [AIModel] = [
		.claudeCodeSonnet,
		.gemini3FlashPreview,
		.gpt54Low,
		// Prioritize fast and affordable models
		.gpt54Mini,
		// Then other cheap/fast models
		.deepseekChat, .openrouterDeepseekChat,
		.gpt41,
		.deepseekReasoner,
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.geminiProLatest, .openrouterGeminiPro,
		.geminiPro25, .openrouterGeminiPro25,
		.geminiFlash25,
		.o3,
		.ollama
	]

	/// "Medium" whole: prefer current Gemini 3.0 Flash, then balanced GPT and fallback models.
	static let mediumWholePriority: [AIModel] = [
		.claudeCodeSonnet,
		.gemini3FlashPreview,
		.gpt54,
		// Then the simple priorities
		.gpt54Mini,
		// fallback: everything else
		.deepseekChat, .openrouterDeepseekChat,
		.gpt41,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.geminiProLatest, .openrouterGeminiPro,
		.geminiPro25, .openrouterGeminiPro25,
		.geminiFlash25,
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
		.o3,
		.ollama
	]

	/// "High" whole: optimized for more expensive models at top
	static let highWholePriority: [AIModel] = [
		// Prioritize higher-quality models for complex whole-file edits
		.claudeCodeSonnet,
		.gpt54High,
		.gemini3FlashPreview,
		.gpt54Mini,
		.geminiFlashLatest,
		// fallback: everything else
		.deepseekChat, .openrouterDeepseekChat,
		.gpt41,
		.zaiGLM5,
		.zaiGLM5_0,
		.zaiGLM5Turbo,
		.zaiGLM47, .zaiGLM47Flash,
		.zaiGLM46,
		.zaiGLM45, .zaiGLM45Air, .zaiGLM45Flash,
		.claude4Sonnet, .openrouterClaude4Sonnet,
		.geminiProLatest, .openrouterGeminiPro,
		.geminiPro25, .openrouterGeminiPro25,
		.geminiFlash25,
		.o3,
		.ollama
	]

	// Priority lists (kept for backward compatibility)
	static let diffPriorityModels: [AIModel] = mediumDiffPriority
	static let wholePriorityModels: [AIModel] = mediumWholePriority

	// ==========================================================
	// FIND BEST AVAILABLE MODEL (with fallback to "other" models)
	// ==========================================================

	// MARK: - Responses-API flag
	/// Returns **true** for built-in `o3-pro` variants.
	/// For *custom-provider* models it defers to `ModelOverridesSettings`.
	/// All other models return `false`.
	var usesResponsesAPI: Bool {
		// Delegate to base for tier variants
		if case .openAIServiceTierVariant(let base, _) = self {
			return base.usesResponsesAPI
		}
		// 1. Built-in support
	if [.gpt5Pro, .gpt5ProXHigh, .gpt54Pro, .gpt54ProXHigh,
	.o3, .o3Low, .o3High,
		.gpt5, .gpt5Low, .gpt5High, .gpt5XHigh,
		.gpt54, .gpt54Low, .gpt54High, .gpt54XHigh,
		.gpt54Mini, .gpt54MiniLow, .gpt54MiniHigh, .gpt54MiniXHigh, .gpt54Nano,
		.gpt5CodexLow, .gpt5CodexMed, .gpt5CodexHigh, .gpt5CodexXHigh].contains(self) { return true }

		if case .openaiCustomResponses = self {
			return true
		}

		if case .openaiCustomReasoning = self {
			return true
		}

		// 2. Custom provider override
		if isCustomProviderModel,
		let override = ModelOverridesSettings.shared.responsesOverride(for: self.rawValue) {
			return override
		}

		// 3. Default
		return false
	}

	static func findBestAvailableModel(
		in availableModels: [AIModel],
		desiredFormat: PromptViewModel.FileEditFormat,
		priorities: [AIModel]
	) -> AIModel? {
		// Filter out models that are not yet available
		let currentlyAvailableModels = availableModels.filter { $0.isAvailable }

		// 1) Try the official priority list
		for candidate in priorities {
			guard let match = currentlyAvailableModels.first(where: { $0 == candidate }) else { continue }
			switch desiredFormat {
			case .diff:
				if match.isModelCapableOfDiff { return match }
			case .whole, .none:
				return match
			}
		}
		// 2) If none found in the list, fallback to ANY leftover model in user's environment
		//    e.g. custom provider or openrouterCustom not in the arrays
		//    Skip service tier variants to prevent accidental selection of explicit tiers
		for possible in currentlyAvailableModels {
			if possible.isOpenAIServiceTierVariant { continue }
			if !priorities.contains(possible) {
				// This means it's "unlisted."
				// Check if it meets the diff requirement if needed:
				switch desiredFormat {
				case .diff:
					if possible.isModelCapableOfDiff { return possible }
				case .whole, .none:
					return possible
				}
			}
		}
		// 3) Return nil if truly nothing is suitable
		return nil
	}

	// Helper check for custom provider or openrouterCustom
	var isCustom: Bool {
		switch self {
		case .customProvider(_, _, _),
		     .customProviderUser(_),
		     .openrouterCustom(_),
		     .openaiCustom(_),
		     .openaiCustomResponses(_),
		     .openaiCustomReasoning(_, _),
		     .anthropicCustom(_),
		     .geminiCustom(_),
		     .deepseekCustom(_),
		     .fireworksCustom(_),
		     .azureCustom(_),
		     .grokCustom(_),
		     .groqCustom(_),
		     .zaiCustom(_),
		     .codexCustom(_),
		     .ollama:
			return true
		default:
			return false
		}
	}

	/// NEW: returns true only for `.customProvider` / `.customProviderUser`
	private var isCustomProviderModel: Bool {
		switch self {
		case .customProvider(_, _, _), .customProviderUser(_):
			return true
		default:
			return false
		}
	}
	
	var isOpenAIModel: Bool {
		if case .openAIServiceTierVariant(let base, _) = self {
			return base.isOpenAIModel
		}
		return Self.modelGroups[ProviderIndex.openAI].contains(self)
	}
	var isAnthropicModel: Bool { Self.modelGroups[ProviderIndex.anthropic].contains(self) }
	var isGeminiModel: Bool { Self.modelGroups[ProviderIndex.gemini].contains(self) }
	var isOpenRouterModel: Bool { Self.modelGroups[ProviderIndex.openRouter].contains(self) || (self.rawValue.starts(with: "openrouter_custom_")) }
	var isOllamaModel: Bool { self == .ollama }
	
	/// Check if a model is currently available based on its release date
	var isAvailable: Bool {
		guard let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }) else {
			return true // Unknown models default to available
		}

		if let releaseDate = modelInfo.availableFrom {
			return Date() >= releaseDate
		}

		return true // No release date means always available
	}

	var isModelCapableOfDiff: Bool {
		// All models use the diff-edit prompt path. Keep this unconditional so legacy
		// allowlists, custom-provider heuristics, and per-model overrides cannot force
		// models back to whole-file rewrite mode.
		true
	}
	
	/// New helper: whether this model can stream.
	var canStream: Bool {
		// Delegate to base for tier variants
		if case .openAIServiceTierVariant(let base, _) = self {
			return base.canStream
		}
		if let override = ModelOverridesSettings.shared.streamOverride(for: self.rawValue) {
			return override
		}
		// Explicitly disable streaming for all Pro variants
		if self == .gpt5Pro || self == .gpt5ProXHigh || self == .gpt54Pro || self == .gpt54ProXHigh {
			return false
		}
		return true
	}

	var defaultReasoningEffort: String? {
		// Delegate to base for tier variants
		if case .openAIServiceTierVariant(let base, _) = self {
			return base.defaultReasoningEffort
		}
		switch self {
		case .gpt5Pro, .gpt54Pro: return "high"
		case .gpt5ProXHigh, .gpt54ProXHigh: return "xhigh"
		case .gpt5XHigh, .gpt54XHigh, .gpt5CodexXHigh: return "xhigh"
		case .gpt5High, .gpt54High, .gpt5CodexHigh, .o3High: return "high"
		case .gpt5, .gpt54, .gpt5CodexMed, .o3: return "medium"
		case .gpt5Low, .gpt54Low, .gpt5CodexLow, .o3Low: return "low"
		// Codex CLI models
		case .codexCliGpt55CodexXHigh, .codexCliGpt5XHigh, .codexCliGpt54XHigh, .codexCliGpt5CodexXHigh: return "xhigh"
		case .codexCliGpt55CodexHigh, .codexCliGpt5High, .codexCliGpt54High, .codexCliGpt5CodexHigh: return "high"
		case .codexCliGpt55CodexMedium, .codexCliGpt5Medium, .codexCliGpt54Medium, .codexCliGpt5CodexMedium: return "medium"
		case .codexCliGpt55CodexLow, .codexCliGpt5Low, .codexCliGpt54Low, .codexCliGpt5CodexLow: return "low"
		case .codexCustom(let name):
			return CodexModelSpecifier(raw: name).reasoningEffort?.rawValue
		case .claudeCodeModel(let specifier):
			return ClaudeModelSpecifier(raw: specifier).explicitEffortLevel?.rawValue
		case .openaiCustomReasoning(_, let effort):
			return effort.rawValue
		default: return nil
		}
	}

	/// Returns the Codex service tier override for this model, if any.
	/// Currently only GPT-5.4 Fast variants request the "fast" service tier.
	var codexServiceTier: String? {
		switch self {
		case .codexCustom(let name):
			let specifier = CodexModelSpecifier(raw: name)
			guard let baseModel = specifier.baseModel else { return nil }
			return CodexServiceTierVariantCatalog.supportedServiceTier(
				baseModelID: baseModel,
				serviceTier: specifier.serviceTier
			)
		default:
			return nil
		}
	}

	func toProviderModel() -> Any {
		// Delegate to base for tier variants
		if case .openAIServiceTierVariant(let base, _) = self {
			return base.toProviderModel()
		}
		switch providerType {
		case .openAI, .gemini, .ollama, .deepseek, .fireworks, .grok, .groq, .zAI: // <-- Add Groq here
			return SwiftOpenAI.Model.custom(self.modelName)
		case .anthropic:
			return SwiftAnthropic.Model.other(self.modelName)
		case .azure, .openRouter, .customProvider, .claudeCode, .codex, .geminiCli, .openCode, .cursor:
			// For these providers, use the actual model name when available
			if let modelInfo = Self.modelDefinitions.first(where: { $0.model == self }),
				let actualName = modelInfo.actualName {
				return SwiftOpenAI.Model.custom(actualName)
			}
			return SwiftOpenAI.Model.custom(self.modelName)
		}
	}
	
	static func fromModelName(_ rawValue: String) -> AIModel? {
		let normalizedRawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		switch normalizedRawValue.lowercased() {
		case "gemini-3-pro-preview":
			return .gemini3p1ProPreview
		case "gemini_cli_pro-3.0-preview":
			return .geminiCliPro3p1Preview
		case "glm-5":
			return .zaiGLM5_0
		default:
			break
		}

		// Handle service tier variants
		if normalizedRawValue.hasPrefix(openAITierPrefix) {
			let rest = String(normalizedRawValue.dropFirst(openAITierPrefix.count))
			let parts = rest.components(separatedBy: "__")
			if parts.count >= 2 {
				let tier = parts[0]
				let baseRaw = parts.dropFirst().joined(separator: "__")
				if let base = AIModel.fromModelName(baseRaw) {
					return .openAIServiceTierVariant(base: base, tier: tier)
				}
			}
		}

		// Handle custom OpenRouter models
		if normalizedRawValue.starts(with: "openrouter_custom_") {
			return .openrouterCustom(name: String(normalizedRawValue.dropFirst("openrouter_custom_".count)))
		}

		// Handle Claude Code CLI provider models with a provider-specific prefix to avoid
		// conflicts with Anthropic API model IDs such as "claude-opus-4-6".
		if normalizedRawValue.hasPrefix(ClaudeCodeAIModelCatalog.rawPrefix) {
			let specifier = String(normalizedRawValue.dropFirst(ClaudeCodeAIModelCatalog.rawPrefix.count))
			return ClaudeCodeAIModelCatalog.validatedModel(specifier: specifier)
		}

		// Agent discovery/app-settings may persist unprefixed Claude Code model raws
		// with explicit effort suffixes, e.g. "claude-opus-4-5:high". Treat the
		// effort suffix as a provider signal so these do not fall through to an
		// unrelated chat-model fallback. Bare no-effort full IDs still use the
		// standard exact resolver below to preserve Anthropic conflict behavior.
		if let claudeCodeModel = ClaudeCodeAIModelCatalog.validatedAgentCatalogEffortModel(specifier: normalizedRawValue) {
			return claudeCodeModel
		}

		// Handle Codex CLI models with prefix
		if normalizedRawValue.starts(with: "codex_cli_") {
			return modelDefinitions.first { $0.rawValue == normalizedRawValue }?.model
		}
		if normalizedRawValue.starts(with: "codex_custom_") {
			return .codexCustom(name: String(normalizedRawValue.dropFirst("codex_custom_".count)))
		}
		if normalizedRawValue.starts(with: "opencode_custom_") {
			return .openCodeCustom(name: String(normalizedRawValue.dropFirst("opencode_custom_".count)))
		}
		if normalizedRawValue.starts(with: "cursor_custom_") {
			return .cursorCustom(name: String(normalizedRawValue.dropFirst("cursor_custom_".count)))
		}
		
		// Handle Gemini CLI models with prefix
		if normalizedRawValue.starts(with: "gemini_cli_") {
			return modelDefinitions.first { $0.rawValue == normalizedRawValue }?.model
		}

		if normalizedRawValue.starts(with: "openai_custom_reasoning_") {
			let rest = String(normalizedRawValue.dropFirst("openai_custom_reasoning_".count))
			let parts = rest.components(separatedBy: "__")
			if parts.count >= 2,
				let effort = CodexReasoningEffort.parse(parts[0]) {
				let name = parts.dropFirst().joined(separator: "__")
				guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
				return .openaiCustomReasoning(name: name, effort: effort)
			}
		}

		if normalizedRawValue.starts(with: "openai_custom_responses_") {
			let name = String(normalizedRawValue.dropFirst("openai_custom_responses_".count))
			guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
			return .openaiCustomResponses(name: name)
		}

		let customPrefixes: [(String, (String)->AIModel)] = [
			("openai_custom_",      { .openaiCustom(name: $0) }),
			("anthropic_custom_",   { .anthropicCustom(name: $0) }),
			("gemini_custom_",      { .geminiCustom(name: $0) }),
			("deepseek_custom_",    { .deepseekCustom(name: $0) }),
			("fireworks_custom_",   { .fireworksCustom(name: $0) }),
			("azure_custom_",       { .azureCustom(name: $0) }),
			("zai_custom_",         { .zaiCustom(name: $0) })
		]
		for (prefix, builder) in customPrefixes where normalizedRawValue.hasPrefix(prefix) {
			return builder(String(normalizedRawValue.dropFirst(prefix.count)))
		}

		// Handle Grok custom models
		if normalizedRawValue.starts(with: "grok_custom_") {
			return .grokCustom(name: String(normalizedRawValue.dropFirst("grok_custom_".count)))
		}
		
		// Handle Groq custom models
		if normalizedRawValue.starts(with: "groq_custom_") {
			return .groqCustom(name: String(normalizedRawValue.dropFirst("groq_custom_".count)))
		}
		
		
		if normalizedRawValue.starts(with: "ollama_") {
			return .ollama
		}
		
		// Handle custom provider models
		if normalizedRawValue.starts(with: "custom_provider_user_") {
			return .customProviderUser(name: String(normalizedRawValue.dropFirst("custom_provider_user_".count)))
		}
		if normalizedRawValue.starts(with: "custom_provider_") {
			let modelName = String(normalizedRawValue.dropFirst("custom_provider_".count))
			if let config = try? CustomProviderConfiguration.load() {
				// Preserve the user's selection and show the real provider name when available
				return .customProvider(name: modelName, provider: config.name, model: modelName)
			} else {
				// Best-effort placeholder; still treats it as a real custom provider model
				return .customProvider(name: modelName, provider: "custom", model: modelName)
			}
		}
		
		// Handle Fireworks models
		if normalizedRawValue.starts(with: "accounts/fireworks/models/") {
			return modelDefinitions.first { $0.rawValue == normalizedRawValue }?.model
		}
	
		// Handle standard models
		return modelData.first(where: { $0.value.rawValue == normalizedRawValue })?.key
	}
	
	static func modelsForProvider(_ provider: AIProviderType) -> [AIModel] {
		let models: [AIModel]
		switch provider {
		case .anthropic:
			models = Array(modelGroups[ProviderIndex.anthropic])
		case .openAI:
			models = Array(modelGroups[ProviderIndex.openAI])
		case .gemini:
			models = Array(modelGroups[ProviderIndex.gemini])
		case .openRouter:
			models = Array(modelGroups[ProviderIndex.openRouter])
		case .deepseek:
			models = Array(modelGroups[ProviderIndex.deepseek])
		case .ollama:
			models = [.ollama]
		case .azure:
			models = Array(modelGroups[ProviderIndex.azure])
		case .customProvider:
			var customModels: [AIModel] = []
			if let config = try? CustomProviderConfiguration.load() {
				customModels.append(.customProvider(name: config.name, provider: "custom", model: config.defaultModel))
				if let userModel = config.userPreferredModel, !userModel.isEmpty {
					customModels.append(.customProviderUser(name: userModel))
				}
			}
			models = customModels
		case .fireworks: // <-- Add Fireworks case
			models = Array(modelGroups[ProviderIndex.fireworks])
		case .grok: // <-- Add Grok case
			models = Array(modelGroups[ProviderIndex.grok])
		case .groq: // <-- Add Groq case
			models = Array(modelGroups[ProviderIndex.groq])
		case .zAI:
			models = Array(modelGroups[ProviderIndex.zAI])
		case .claudeCode:
			models = ClaudeCodeAIModelCatalog.modelsForPicker()
		case .codex:
			models = codexModelsForPicker()
		case .geminiCli:
			models = Array(modelGroups[ProviderIndex.geminiAgent])
		case .openCode:
			models = ACPAIModelCatalog.openCodeModelsFromStore()
		case .cursor:
			models = ACPAIModelCatalog.cursorModelsFromStore()
		}

		// Filter out models that are not yet available based on their release date
		return models.filter { $0.isAvailable }
	}

	struct CodexPickerMenuGroup: Identifiable, Hashable {
		let baseModelID: String
		let displayName: String
		let models: [AIModel]

		var id: String { baseModelID.lowercased() }
	}

	struct OpenCodePickerMenuOption: Identifiable, Hashable {
		let model: AIModel
		let displayName: String

		var id: String { model.rawValue }
	}

	struct OpenCodePickerMenuGroup: Identifiable, Hashable {
		let baseModelID: String
		let displayName: String
		let modelDisplayName: String
		let options: [OpenCodePickerMenuOption]
		let rendersAsSubmenu: Bool

		var id: String { baseModelID.lowercased() }
	}

	struct OpenCodePickerProviderMenuGroup: Identifiable, Hashable {
		let providerID: String?
		let displayName: String
		let groups: [OpenCodePickerMenuGroup]
		let rendersAsSubmenu: Bool

		var id: String { providerID?.lowercased() ?? "_root" }
	}

	struct OpenCodePickerMenu: Hashable {
		let providerGroups: [OpenCodePickerProviderMenuGroup]
		let groups: [OpenCodePickerMenuGroup]
	}

	struct ClaudeCodePickerMenuOption: Identifiable, Hashable {
		let model: AIModel
		let displayName: String

		var id: String { model.rawValue }
	}

	struct ClaudeCodePickerMenuGroup: Identifiable, Hashable {
		let baseModelRaw: String
		let displayName: String
		let options: [ClaudeCodePickerMenuOption]
		let rendersAsSubmenu: Bool

		var id: String { baseModelRaw.lowercased() }
	}

	struct ClaudeCodePickerMenu: Hashable {
		let defaultOption: ClaudeCodePickerMenuOption?
		let groups: [ClaudeCodePickerMenuGroup]
	}

	private struct SemanticSortMetadata {
		let family: String
		let versionComponents: [Int]
		let suffix: String
		let reasoningEffort: CodexReasoningEffort?
		let displayName: String
		let tieBreaker: String
	}

	static func sortedForPicker(_ models: [AIModel]) -> [AIModel] {
		var metadataCache: [AIModel: SemanticSortMetadata] = [:]
		func metadata(for model: AIModel) -> SemanticSortMetadata {
			if let cached = metadataCache[model] {
				return cached
			}
			let metadata = semanticSortMetadata(for: model)
			metadataCache[model] = metadata
			return metadata
		}

		return models.sorted { lhs, rhs in
			if lhs.providerType != rhs.providerType {
				return AIProviderType.pickerSortPrecedes(lhs.providerType, rhs.providerType)
			}
			if lhs.providerType == .claudeCode {
				return ClaudeCodeAIModelCatalog.modelPrecedes(lhs, rhs)
			}
			return semanticMetadataPrecedes(metadata(for: lhs), metadata(for: rhs))
		}
	}

	static func pickerSortComparator(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
		if lhs.providerType != rhs.providerType {
			return AIProviderType.pickerSortPrecedes(lhs.providerType, rhs.providerType)
		}
		if lhs.providerType == .claudeCode {
			return ClaudeCodeAIModelCatalog.modelPrecedes(lhs, rhs)
		}
		return semanticModelPrecedes(lhs, rhs)
	}

	static func claudeCodeMenu(for models: [AIModel]) -> ClaudeCodePickerMenu {
		ClaudeCodeAIModelCatalog.menu(for: models)
	}

	static func openCodeMenu(for models: [AIModel]) -> OpenCodePickerMenu {
		var modelsByName: [String: AIModel] = [:]
		var sourceOptionsByRaw: [String: AgentModelOption] = [:]
		for option in ACPAIModelCatalog.openCodeModelOptionsFromStore() {
			let key = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard !key.isEmpty, sourceOptionsByRaw[key] == nil else { continue }
			sourceOptionsByRaw[key] = option
		}
		let options = models.compactMap { model -> AgentModelOption? in
			guard model.providerType == .openCode else { return nil }
			let modelName = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !modelName.isEmpty else { return nil }
			modelsByName[modelName.lowercased()] = model
			let sourceOption = sourceOptionsByRaw[modelName.lowercased()]
			return AgentModelOption(
				rawValue: modelName,
				displayName: sourceOption?.displayName ?? modelName,
				description: sourceOption?.description,
				isPlaceholderDefault: sourceOption?.isPlaceholderDefault ?? false,
				isProviderDefault: sourceOption?.isProviderDefault ?? false,
				supportedReasoningEfforts: sourceOption?.supportedReasoningEfforts ?? [],
				defaultReasoningEffort: sourceOption?.defaultReasoningEffort
			)
		}

		let catalogMenu = AgentModelCatalog.openCodeMenu(for: options)
		var groupsByID: [String: OpenCodePickerMenuGroup] = [:]
		let groups = catalogMenu.groups.compactMap { group -> OpenCodePickerMenuGroup? in
			let menuOptions = group.options.compactMap { menuOption -> OpenCodePickerMenuOption? in
				guard let model = modelsByName[menuOption.option.rawValue.lowercased()] else { return nil }
				return OpenCodePickerMenuOption(model: model, displayName: menuOption.displayName)
			}
			guard !menuOptions.isEmpty else { return nil }
			let pickerGroup = OpenCodePickerMenuGroup(
				baseModelID: group.baseModelID,
				displayName: group.displayName,
				modelDisplayName: group.modelDisplayName,
				options: menuOptions,
				rendersAsSubmenu: group.rendersAsSubmenu
			)
			groupsByID[group.id] = pickerGroup
			return pickerGroup
		}
		let providerGroups = catalogMenu.providerGroups.compactMap { providerGroup -> OpenCodePickerProviderMenuGroup? in
			let pickerGroups = providerGroup.groups.compactMap { groupsByID[$0.id] }
			guard !pickerGroups.isEmpty else { return nil }
			return OpenCodePickerProviderMenuGroup(
				providerID: providerGroup.providerID,
				displayName: providerGroup.displayName,
				groups: pickerGroups,
				rendersAsSubmenu: providerGroup.rendersAsSubmenu
			)
		}
		return OpenCodePickerMenu(providerGroups: providerGroups, groups: groups)
	}

	static func openCodeMenuGroups(for models: [AIModel]) -> [OpenCodePickerMenuGroup] {
		openCodeMenu(for: models).groups
	}

	static func codexMenuGroups(for models: [AIModel]) -> [CodexPickerMenuGroup] {
		struct Entry {
			let model: AIModel
			let baseModelID: String
			let displayName: String
			let reasoningEffort: CodexReasoningEffort?
		}

		let entries = models.map { model in
			let baseModelID = codexBaseModelID(for: model)
			let modelDisplayName = model.displayName
			return Entry(
				model: model,
				baseModelID: baseModelID,
				displayName: codexBaseDisplayName(for: baseModelID, fallbackDisplayName: modelDisplayName),
				reasoningEffort: codexReasoningEffort(for: model, fallbackLabel: modelDisplayName)
			)
		}

		let grouped = Dictionary(grouping: entries, by: { $0.baseModelID.lowercased() })
		return grouped.values.compactMap { groupEntries in
			guard let representative = groupEntries.first else { return nil }
			let sortedModels = groupEntries.sorted { lhs, rhs in
				let leftRank = reasoningSortRank(lhs.reasoningEffort)
				let rightRank = reasoningSortRank(rhs.reasoningEffort)
				if leftRank != rightRank {
					return leftRank < rightRank
				}
				return semanticModelPrecedes(lhs.model, rhs.model)
			}.map(\.model)

			return CodexPickerMenuGroup(
				baseModelID: representative.baseModelID,
				displayName: representative.displayName,
				models: sortedModels
			)
		}.sorted { lhs, rhs in
			if codexBaseModelPrecedes(lhs.baseModelID, rhs.baseModelID) { return true }
			if codexBaseModelPrecedes(rhs.baseModelID, lhs.baseModelID) { return false }
			return ModelPickerStringOrdering.precedes(lhs.displayName, rhs.displayName)
		}
	}

	static func codexBaseModelPrecedes(_ lhs: String, _ rhs: String) -> Bool {
		let leftMetadata = semanticSortMetadata(identifier: lhs, fallbackDisplayName: lhs, reasoningEffort: nil)
		let rightMetadata = semanticSortMetadata(identifier: rhs, fallbackDisplayName: rhs, reasoningEffort: nil)
		return semanticMetadataPrecedes(leftMetadata, rightMetadata)
	}

	static func codexBaseDisplayName(for baseModelID: String, fallbackDisplayName: String) -> String {
		if let storeLabel = CodexDynamicModelStore.displayName(forModelID: baseModelID) {
			let normalizedStoreLabel = normalizedCodexBaseLabel(storeLabel)
			if !normalizedStoreLabel.isEmpty {
				return codexPreviewDisplayAlias(for: normalizedStoreLabel) ?? normalizedStoreLabel
			}
		}

		let fallbackLabel = normalizedCodexBaseLabel(fallbackDisplayName)
		if !fallbackLabel.isEmpty {
			return humanizedCodexBaseModel(fallbackLabel)
		}

		return humanizedCodexBaseModel(baseModelID)
	}

	static func codexPreviewDisplayAlias(for raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }

		let specifier = CodexModelSpecifier(raw: trimmed)
		let base = specifier.baseModel ?? trimmed
		let normalizedBase = normalizedSemanticText(base)
		guard normalizedBase == "gpt-5.5" || normalizedBase == "gpt-5.5" else { return nil }

		var label = "GPT-5.5"
		if let serviceTier = specifier.serviceTier {
			label += serviceTier == CodexServiceTierVariantCatalog.fastServiceTier ? " Fast" : " \(serviceTier.capitalized)"
		}
		if let reasoningEffort = specifier.reasoningEffort {
			label += " \(reasoningEffort.displayName)"
		}
		return label
	}

	static func stripCodexReasoningSuffix(from label: String) -> String {
		let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return trimmed }

		let suffixes = [
			"-xhigh", " xhigh", "-x-high", " x-high",
			"-medium", " medium", "-med", " med",
			"-minimal", " minimal",
			"-high", " high",
			"-none", " none",
			"-low", " low"
		]
		let lowered = trimmed.lowercased()
		for suffix in suffixes where lowered.hasSuffix(suffix) {
			return String(trimmed.dropLast(suffix.count))
				.trimmingCharacters(in: CharacterSet(charactersIn: " -_/·"))
		}

		return trimmed
	}

	private static func semanticModelPrecedes(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
		let leftMetadata = semanticSortMetadata(for: lhs)
		let rightMetadata = semanticSortMetadata(for: rhs)
		return semanticMetadataPrecedes(leftMetadata, rightMetadata)
	}

	private static func semanticMetadataPrecedes(_ lhs: SemanticSortMetadata, _ rhs: SemanticSortMetadata) -> Bool {
		let familyComparison = ModelPickerStringOrdering.compare(lhs.family, rhs.family, caseInsensitiveASCII: true)
		if familyComparison != .orderedSame {
			return familyComparison == .orderedAscending
		}

		let versionComparison = compareVersionComponents(lhs.versionComponents, rhs.versionComponents)
		if versionComparison != .orderedSame {
			return versionComparison == .orderedDescending
		}

		let leftReasoningRank = reasoningSortRank(lhs.reasoningEffort)
		let rightReasoningRank = reasoningSortRank(rhs.reasoningEffort)
		if leftReasoningRank != rightReasoningRank {
			return leftReasoningRank < rightReasoningRank
		}

		let suffixComparison = ModelPickerStringOrdering.compare(lhs.suffix, rhs.suffix, caseInsensitiveASCII: true)
		if suffixComparison != .orderedSame {
			return suffixComparison == .orderedAscending
		}

		let displayComparison = ModelPickerStringOrdering.compare(lhs.displayName, rhs.displayName, caseInsensitiveASCII: true)
		if displayComparison != .orderedSame {
			return displayComparison == .orderedAscending
		}

		return ModelPickerStringOrdering.precedes(lhs.tieBreaker, rhs.tieBreaker)
	}

	private static func semanticSortMetadata(for model: AIModel) -> SemanticSortMetadata {
		let identifier = model.providerType == .codex ? codexBaseModelID(for: model) : model.modelName
		let sortLabel = semanticSortLabel(for: model)
		let reasoningEffort = codexReasoningEffort(for: model, fallbackLabel: sortLabel)

		return semanticSortMetadata(
			identifier: identifier,
			fallbackDisplayName: sortLabel,
			reasoningEffort: reasoningEffort
		)
	}

	private static func semanticSortLabel(for model: AIModel) -> String {
		switch model {
		case .codexCustom(let name), .openCodeCustom(let name), .cursorCustom(let name):
			return name
		default:
			return model.displayName
		}
	}

	private static func semanticSortMetadata(
		identifier: String,
		fallbackDisplayName: String,
		reasoningEffort: CodexReasoningEffort?
	) -> SemanticSortMetadata {
		let semanticSource = codexPreviewDisplayAlias(for: identifier) ?? (identifier.isEmpty ? fallbackDisplayName : identifier)
		let normalizedIdentifier = normalizedSemanticText(semanticSource)
		let family = semanticFamily(in: normalizedIdentifier)
		let versionComponents = semanticVersionComponents(in: normalizedIdentifier)
		let suffix = semanticSuffix(in: normalizedIdentifier)

		return SemanticSortMetadata(
			family: family,
			versionComponents: versionComponents,
			suffix: suffix,
			reasoningEffort: reasoningEffort,
			displayName: fallbackDisplayName,
			tieBreaker: identifier
		)
	}

	private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
		guard !lhs.isEmpty || !rhs.isEmpty else { return .orderedSame }

		let maxCount = max(lhs.count, rhs.count)
		for index in 0..<maxCount {
			let leftValue = index < lhs.count ? lhs[index] : -1
			let rightValue = index < rhs.count ? rhs[index] : -1
			if leftValue == rightValue { continue }
			return leftValue < rightValue ? .orderedAscending : .orderedDescending
		}

		return .orderedSame
	}

	private static func reasoningSortRank(_ effort: CodexReasoningEffort?) -> Int {
		guard let effort else { return -1 }
		return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
	}

	private static func codexBaseModelID(for model: AIModel) -> String {
		let specifier = CodexModelSpecifier(raw: model.modelName)
		var candidate = specifier.baseModel ?? model.modelName
		// Preserve service tier in the grouping key so fast/flex variants get their own picker group
		if let tier = specifier.serviceTier {
			candidate += "-\(tier)"
		}
		return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func codexReasoningEffort(
		for model: AIModel,
		fallbackLabel: String? = nil
	) -> CodexReasoningEffort? {
		let specifier = CodexModelSpecifier(raw: model.modelName)
		return specifier.reasoningEffort
			?? reasoningEffort(in: model.modelName)
			?? fallbackLabel.flatMap(reasoningEffort(in:))
	}

	private static func reasoningEffort(in text: String) -> CodexReasoningEffort? {
		let tokens = text
			.lowercased()
			.replacingOccurrences(of: "(", with: " ")
			.replacingOccurrences(of: ")", with: " ")
			.replacingOccurrences(of: "·", with: " ")
			.split { !$0.isLetter && !$0.isNumber }
			.map(String.init)

		for token in tokens.reversed() {
			if token == "med" {
				return .medium
			}
			if let parsed = CodexReasoningEffort.parse(token) {
				return parsed
			}
		}

		return nil
	}

	private static func normalizedCodexBaseLabel(_ label: String) -> String {
		let withoutPrefix = label
			.replacingOccurrences(of: "CLI·", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return stripCodexReasoningSuffix(from: withoutPrefix)
	}

	private static func humanizedCodexBaseModel(_ raw: String) -> String {
		if let alias = codexPreviewDisplayAlias(for: raw) {
			return alias
		}

		let tokens = raw.split { character in
			character == "_" || character == "-" || character == "/" || character.isWhitespace
		}
		guard !tokens.isEmpty else { return raw }

		var formatted: [String] = []
		formatted.reserveCapacity(tokens.count)
		for token in tokens {
			let value = String(token)
			let formattedToken = formatCodexLabelToken(value)
			if isVersionToken(value), formatted.last == "GPT" {
				formatted[formatted.count - 1] = "GPT-\(formattedToken)"
			} else {
				formatted.append(formattedToken)
			}
		}
		return formatted.joined(separator: " ")
	}

	private static func formatCodexLabelToken(_ value: String) -> String {
		let lower = value.lowercased()
		if lower == "gpt" { return "GPT" }
		if lower == "codex" { return "Codex" }
		if lower == "xhigh" { return "XHigh" }
		if isVersionToken(value) { return value }
		return lower.capitalized
	}

	private static func isVersionToken(_ value: String) -> Bool {
		let parts = value.split(separator: ".", omittingEmptySubsequences: false)
		guard !parts.isEmpty else { return false }
		return parts.allSatisfy { part in
			!part.isEmpty && part.allSatisfy(\.isNumber)
		}
	}

	private static func normalizedSemanticText(_ text: String) -> String {
		var output = ""
		var previousWasSeparator = false
		for character in text.lowercased() {
			if character == "·" || character == "_" || character.isWhitespace {
				if !previousWasSeparator {
					output.append("-")
					previousWasSeparator = true
				}
			} else {
				output.append(character)
				previousWasSeparator = false
			}
		}
		return output.trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
	}

	private static func semanticFamily(in text: String) -> String {
		guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
			return text
		}

		let prefix = text[..<firstNumberIndex]
			.trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
		return prefix.isEmpty ? text : String(prefix)
	}

	private static func semanticVersionComponents(in text: String) -> [Int] {
		guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
			return []
		}

		var cursor = firstNumberIndex
		var versionString = ""
		while cursor < text.endIndex {
			let character = text[cursor]
			if character.isNumber || character == "." {
				versionString.append(character)
				cursor = text.index(after: cursor)
				continue
			}
			break
		}

		return versionString
			.split(separator: ".")
			.compactMap { Int($0) }
	}

	private static func semanticSuffix(in text: String) -> String {
		guard let firstNumberIndex = text.firstIndex(where: { $0.isNumber }) else {
			return text
		}

		var cursor = firstNumberIndex
		while cursor < text.endIndex {
			let character = text[cursor]
			if character.isNumber || character == "." {
				cursor = text.index(after: cursor)
				continue
			}
			break
		}

		return text[cursor...]
			.trimmingCharacters(in: CharacterSet(charactersIn: "- /"))
	}
	
	static func allModels() -> [AIModel] {
		var models: [AIModel] = []
		for (providerIndex, group) in modelGroups.enumerated() {
			if providerIndex == ProviderIndex.claudeCode {
				models.append(contentsOf: ClaudeCodeAIModelCatalog.modelsForPicker())
			} else if providerIndex == ProviderIndex.codex {
				models.append(contentsOf: codexModelsForPicker())
			} else if providerIndex == ProviderIndex.openCode {
				models.append(contentsOf: ACPAIModelCatalog.openCodeModelsFromStore())
			} else if providerIndex == ProviderIndex.cursor {
				models.append(contentsOf: ACPAIModelCatalog.cursorModelsFromStore())
			} else {
				models.append(contentsOf: group)
			}
		}
		models.append(.ollama)
		// Filter out models that are not yet available based on their release date
		return models.filter { $0.isAvailable }
	}
	
	private indirect enum AIModelIdentity: Hashable {
		case openAIServiceTierVariant(base: AIModelIdentity, tier: String)
		case openrouterCustom(name: String)
		case openaiCustom(name: String)
		case openaiCustomResponses(name: String)
		case openaiCustomReasoning(name: String, effort: CodexReasoningEffort)
		case anthropicCustom(name: String)
		case geminiCustom(name: String)
		case deepseekCustom(name: String)
		case fireworksCustom(name: String)
		case azureCustom(name: String)
		case grokCustom(name: String)
		case groqCustom(name: String)
		case zaiCustom(name: String)
		case codexCustom(name: String)
		case openCodeCustom(name: String)
		case cursorCustom(name: String)
		case customProvider(name: String, provider: String, model: String)
		case customProviderUser(name: String)
		case claudeCodeModel(normalizedSpecifier: String)
		case staticCase(StaticIdentity)
	}

	private enum StaticIdentity: Hashable {
		case gpt41
		case gpt5
		case gpt5Low
		case gpt5High
		case gpt5XHigh
		case gpt54
		case gpt54Low
		case gpt54High
		case gpt54XHigh
		case gpt54Mini
		case gpt54MiniLow
		case gpt54MiniHigh
		case gpt54MiniXHigh
		case gpt54Nano
		case gpt5CodexLow
		case gpt5CodexMed
		case gpt5CodexHigh
		case gpt5CodexXHigh
		case codexCliGpt55CodexLow
		case codexCliGpt55CodexMedium
		case codexCliGpt55CodexHigh
		case codexCliGpt55CodexXHigh
		case codexCliGpt5Low
		case codexCliGpt5Medium
		case codexCliGpt5High
		case codexCliGpt5XHigh
		case codexCliGpt54Low
		case codexCliGpt54Medium
		case codexCliGpt54High
		case codexCliGpt54XHigh
		case codexCliGpt5Mini
		case codexCliGpt5CodexLow
		case codexCliGpt5CodexMedium
		case codexCliGpt5CodexHigh
		case codexCliGpt5CodexXHigh
		case codexCliGpt5CodexMini
		case geminiCliFlash25
		case geminiCliPro25
		case geminiCliPro3p1Preview
		case geminiCliFlash3Preview
		case gpt4o
		case o3
		case o1Preview
		case o1Mini
		case gpt5Pro
		case gpt5ProXHigh
		case gpt54Pro
		case gpt54ProXHigh
		case o3Low
		case o3High
		case claude45Haiku
		case claude4Sonnet
		case claude4SonnetThinking
		case claude4SonnetThinkingMax
		case claude4Opus
		case claude4OpusThinking
		case geminiFlashLatest
		case gemini2flashlite
		case geminiProLatest
		case geminiFlash2
		case geminiFlash25
		case geminiFlash25LitePreview
		case geminiFlashThinking
		case geminiPro25
		case gemini3p1ProPreview
		case gemini3FlashPreview
		case deepseekChat
		case deepseekReasoner
		case ollama
		case openrouterDeepseekChat
		case openrouterGpt5
		case openrouterGeminiFlash
		case openrouterGeminiPro
		case openrouterClaude4Sonnet
		case openrouterClaude4Opus
		case openrouterGeminiPro25
		case fireworksDeepseekV3p1Terminus
		case fireworksGLM46
		case fireworksKimiK2Instruct0905
		case fireworksGptOss120b
		case fireworksQwen3235bA22bThinking2507
		case fireworksQwen3Coder480bA35bInstruct
		case fireworksQwen3235bA22bInstruct2507
		case grok40709
		case grokCodeFast1
		case grok4FastReasoning
		case grok4FastNonReasoning
		case groqKimi
		case zaiGLM5
		case zaiGLM5_0
		case zaiGLM5Turbo
		case zaiGLM47
		case zaiGLM47Flash
		case zaiGLM46
		case zaiGLM45
		case zaiGLM45Air
		case zaiGLM45Flash
		case claudeCode
		case claudeCodeSonnet
		case claudeCodeHaiku
		case claudeCodeOpus
	}

	private var identity: AIModelIdentity {
		switch self {
		case .openAIServiceTierVariant(let base, let tier):
			return .openAIServiceTierVariant(base: base.identity, tier: tier)
		case .openrouterCustom(let name):
			return .openrouterCustom(name: name)
		case .openaiCustom(let name):
			return .openaiCustom(name: name)
		case .openaiCustomResponses(let name):
			return .openaiCustomResponses(name: name)
		case .openaiCustomReasoning(let name, let effort):
			return .openaiCustomReasoning(name: name, effort: effort)
		case .anthropicCustom(let name):
			return .anthropicCustom(name: name)
		case .geminiCustom(let name):
			return .geminiCustom(name: name)
		case .deepseekCustom(let name):
			return .deepseekCustom(name: name)
		case .fireworksCustom(let name):
			return .fireworksCustom(name: name)
		case .azureCustom(let name):
			return .azureCustom(name: name)
		case .grokCustom(let name):
			return .grokCustom(name: name)
		case .groqCustom(let name):
			return .groqCustom(name: name)
		case .zaiCustom(let name):
			return .zaiCustom(name: name)
		case .codexCustom(let name):
			return .codexCustom(name: name)
		case .openCodeCustom(let name):
			return .openCodeCustom(name: name)
		case .cursorCustom(let name):
			return .cursorCustom(name: name)
		case .customProvider(let name, let provider, let model):
			return .customProvider(name: name, provider: provider, model: model)
		case .customProviderUser(let name):
			return .customProviderUser(name: name)
		case .claudeCodeModel(let specifier):
			return .claudeCodeModel(normalizedSpecifier: ClaudeCodeAIModelCatalog.normalizedSpecifier(specifier))
		case .gpt41:
			return .staticCase(.gpt41)
		case .gpt5:
			return .staticCase(.gpt5)
		case .gpt5Low:
			return .staticCase(.gpt5Low)
		case .gpt5High:
			return .staticCase(.gpt5High)
		case .gpt5XHigh:
			return .staticCase(.gpt5XHigh)
		case .gpt54:
			return .staticCase(.gpt54)
		case .gpt54Low:
			return .staticCase(.gpt54Low)
		case .gpt54High:
			return .staticCase(.gpt54High)
		case .gpt54XHigh:
			return .staticCase(.gpt54XHigh)
		case .gpt54Mini:
			return .staticCase(.gpt54Mini)
		case .gpt54MiniLow:
			return .staticCase(.gpt54MiniLow)
		case .gpt54MiniHigh:
			return .staticCase(.gpt54MiniHigh)
		case .gpt54MiniXHigh:
			return .staticCase(.gpt54MiniXHigh)
		case .gpt54Nano:
			return .staticCase(.gpt54Nano)
		case .gpt5CodexLow:
			return .staticCase(.gpt5CodexLow)
		case .gpt5CodexMed:
			return .staticCase(.gpt5CodexMed)
		case .gpt5CodexHigh:
			return .staticCase(.gpt5CodexHigh)
		case .gpt5CodexXHigh:
			return .staticCase(.gpt5CodexXHigh)
		case .codexCliGpt55CodexLow:
			return .staticCase(.codexCliGpt55CodexLow)
		case .codexCliGpt55CodexMedium:
			return .staticCase(.codexCliGpt55CodexMedium)
		case .codexCliGpt55CodexHigh:
			return .staticCase(.codexCliGpt55CodexHigh)
		case .codexCliGpt55CodexXHigh:
			return .staticCase(.codexCliGpt55CodexXHigh)
		case .codexCliGpt5Low:
			return .staticCase(.codexCliGpt5Low)
		case .codexCliGpt5Medium:
			return .staticCase(.codexCliGpt5Medium)
		case .codexCliGpt5High:
			return .staticCase(.codexCliGpt5High)
		case .codexCliGpt5XHigh:
			return .staticCase(.codexCliGpt5XHigh)
		case .codexCliGpt54Low:
			return .staticCase(.codexCliGpt54Low)
		case .codexCliGpt54Medium:
			return .staticCase(.codexCliGpt54Medium)
		case .codexCliGpt54High:
			return .staticCase(.codexCliGpt54High)
		case .codexCliGpt54XHigh:
			return .staticCase(.codexCliGpt54XHigh)
		case .codexCliGpt5Mini:
			return .staticCase(.codexCliGpt5Mini)
		case .codexCliGpt5CodexLow:
			return .staticCase(.codexCliGpt5CodexLow)
		case .codexCliGpt5CodexMedium:
			return .staticCase(.codexCliGpt5CodexMedium)
		case .codexCliGpt5CodexHigh:
			return .staticCase(.codexCliGpt5CodexHigh)
		case .codexCliGpt5CodexXHigh:
			return .staticCase(.codexCliGpt5CodexXHigh)
		case .codexCliGpt5CodexMini:
			return .staticCase(.codexCliGpt5CodexMini)
		case .geminiCliFlash25:
			return .staticCase(.geminiCliFlash25)
		case .geminiCliPro25:
			return .staticCase(.geminiCliPro25)
		case .geminiCliPro3p1Preview:
			return .staticCase(.geminiCliPro3p1Preview)
		case .geminiCliFlash3Preview:
			return .staticCase(.geminiCliFlash3Preview)
		case .gpt4o:
			return .staticCase(.gpt4o)
		case .o3:
			return .staticCase(.o3)
		case .o1Preview:
			return .staticCase(.o1Preview)
		case .o1Mini:
			return .staticCase(.o1Mini)
		case .gpt5Pro:
			return .staticCase(.gpt5Pro)
		case .gpt5ProXHigh:
			return .staticCase(.gpt5ProXHigh)
		case .gpt54Pro:
			return .staticCase(.gpt54Pro)
		case .gpt54ProXHigh:
			return .staticCase(.gpt54ProXHigh)
		case .o3Low:
			return .staticCase(.o3Low)
		case .o3High:
			return .staticCase(.o3High)
		case .claude45Haiku:
			return .staticCase(.claude45Haiku)
		case .claude4Sonnet:
			return .staticCase(.claude4Sonnet)
		case .claude4SonnetThinking:
			return .staticCase(.claude4SonnetThinking)
		case .claude4SonnetThinkingMax:
			return .staticCase(.claude4SonnetThinkingMax)
		case .claude4Opus:
			return .staticCase(.claude4Opus)
		case .claude4OpusThinking:
			return .staticCase(.claude4OpusThinking)
		case .geminiFlashLatest:
			return .staticCase(.geminiFlashLatest)
		case .gemini2flashlite:
			return .staticCase(.gemini2flashlite)
		case .geminiProLatest:
			return .staticCase(.geminiProLatest)
		case .geminiFlash2:
			return .staticCase(.geminiFlash2)
		case .geminiFlash25:
			return .staticCase(.geminiFlash25)
		case .geminiFlash25LitePreview:
			return .staticCase(.geminiFlash25LitePreview)
		case .geminiFlashThinking:
			return .staticCase(.geminiFlashThinking)
		case .geminiPro25:
			return .staticCase(.geminiPro25)
		case .gemini3p1ProPreview:
			return .staticCase(.gemini3p1ProPreview)
		case .gemini3FlashPreview:
			return .staticCase(.gemini3FlashPreview)
		case .deepseekChat:
			return .staticCase(.deepseekChat)
		case .deepseekReasoner:
			return .staticCase(.deepseekReasoner)
		case .ollama:
			return .staticCase(.ollama)
		case .openrouterDeepseekChat:
			return .staticCase(.openrouterDeepseekChat)
		case .openrouterGpt5:
			return .staticCase(.openrouterGpt5)
		case .openrouterGeminiFlash:
			return .staticCase(.openrouterGeminiFlash)
		case .openrouterGeminiPro:
			return .staticCase(.openrouterGeminiPro)
		case .openrouterClaude4Sonnet:
			return .staticCase(.openrouterClaude4Sonnet)
		case .openrouterClaude4Opus:
			return .staticCase(.openrouterClaude4Opus)
		case .openrouterGeminiPro25:
			return .staticCase(.openrouterGeminiPro25)
		case .fireworksDeepseekV3p1Terminus:
			return .staticCase(.fireworksDeepseekV3p1Terminus)
		case .fireworksGLM46:
			return .staticCase(.fireworksGLM46)
		case .fireworksKimiK2Instruct0905:
			return .staticCase(.fireworksKimiK2Instruct0905)
		case .fireworksGptOss120b:
			return .staticCase(.fireworksGptOss120b)
		case .fireworksQwen3235bA22bThinking2507:
			return .staticCase(.fireworksQwen3235bA22bThinking2507)
		case .fireworksQwen3Coder480bA35bInstruct:
			return .staticCase(.fireworksQwen3Coder480bA35bInstruct)
		case .fireworksQwen3235bA22bInstruct2507:
			return .staticCase(.fireworksQwen3235bA22bInstruct2507)
		case .grok40709:
			return .staticCase(.grok40709)
		case .grokCodeFast1:
			return .staticCase(.grokCodeFast1)
		case .grok4FastReasoning:
			return .staticCase(.grok4FastReasoning)
		case .grok4FastNonReasoning:
			return .staticCase(.grok4FastNonReasoning)
		case .groqKimi:
			return .staticCase(.groqKimi)
		case .zaiGLM5:
			return .staticCase(.zaiGLM5)
		case .zaiGLM5_0:
			return .staticCase(.zaiGLM5_0)
		case .zaiGLM5Turbo:
			return .staticCase(.zaiGLM5Turbo)
		case .zaiGLM47:
			return .staticCase(.zaiGLM47)
		case .zaiGLM47Flash:
			return .staticCase(.zaiGLM47Flash)
		case .zaiGLM46:
			return .staticCase(.zaiGLM46)
		case .zaiGLM45:
			return .staticCase(.zaiGLM45)
		case .zaiGLM45Air:
			return .staticCase(.zaiGLM45Air)
		case .zaiGLM45Flash:
			return .staticCase(.zaiGLM45Flash)
		case .claudeCode:
			return .staticCase(.claudeCode)
		case .claudeCodeSonnet:
			return .staticCase(.claudeCodeSonnet)
		case .claudeCodeHaiku:
			return .staticCase(.claudeCodeHaiku)
		case .claudeCodeOpus:
			return .staticCase(.claudeCodeOpus)
		}
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(identity)
	}
	
	public static func == (lhs: AIModel, rhs: AIModel) -> Bool {
		lhs.identity == rhs.identity
	}

	// MARK: - Max Tokens ------------------------------------------------
	/// Optional per-model max tokens.
	/// Returns `nil` when the provider default should be used.
	var maxTokens: Int? {
		switch self {
		// Fireworks models with specific max tokens
		case .fireworksDeepseekV3p1Terminus:
			return 20480
		case .fireworksGLM46:
			return 25344
		case .fireworksKimiK2Instruct0905:
			return 32768
		case .fireworksGptOss120b:
			return 16384
		case .fireworksQwen3235bA22bThinking2507:
			return 32768
		case .fireworksQwen3Coder480bA35bInstruct:
			return 32768
		case .fireworksQwen3235bA22bInstruct2507:
			return 32768
		default:
			return nil
		}
	}

	// MARK: - Default Temperature ------------------------------------------------
	/// Optional per-model default temperature.
	/// Returns `nil` when the global app temperature should be used.
	var defaultTemperature: Double? {
		switch self {
		// Gemini Pro 2.5
		case .geminiPro25, .openrouterGeminiPro25:
			return 0.7
		// DeepSeek R1
		case .deepseekReasoner:
			return 0.6
		// DeepSeek V3p1 Terminus
		case .fireworksDeepseekV3p1Terminus:
			return 0.6
		// GLM-4.6
		case .fireworksGLM46:
			return 0.6
		// Kimi K2 Instruct 0905
		case .fireworksKimiK2Instruct0905:
			return 0.6
		// OpenAI gpt-oss-120b
		case .fireworksGptOss120b:
			return 0.6
		// Qwen3 235B A22B Thinking 2507
		case .fireworksQwen3235bA22bThinking2507:
			return 0.6
		// Qwen3 Coder 480B A35B Instruct
		case .fireworksQwen3Coder480bA35bInstruct:
			return 0.6
		// Qwen3 235B A22B Instruct 2507
		case .fireworksQwen3235bA22bInstruct2507:
			return 0.6
		default:
			return nil
		}
	}

	/// Resolves the actual temperature that will be used for this model,
	/// taking into account overrides, explicit values, and model defaults.
	/// Returns nil when the temperature is not determinable (e.g., API uses its own default).
	/// - Parameters:
	///   - explicitTemperature: Optional explicit temperature (e.g., from benchmark settings)
	///   - includeOverrides: Whether per-model overrides should be considered (default: true)
	/// - Returns: The resolved temperature value, or nil if unknown
	func resolveTemperature(explicitTemperature: Double? = nil, includeOverrides: Bool = true) -> Double? {
		// 1. Per-model override from settings
		if includeOverrides,
		   let override = ModelOverridesSettings.shared.temperatureOverride(for: self.rawValue) {
			return override
		}

		// 2. Explicit temperature passed in (e.g., benchmark override)
		if let explicit = explicitTemperature, explicit > 0.0 {
			return explicit
		}

		// 3. Model-specific default
		if let modelDefault = self.defaultTemperature {
			return modelDefault
		}

		// 4. Provider-specific behavior when effectiveTemperature returns nil
		switch self.providerType {
		case .anthropic:
			// AnthropicProvider explicitly sets temperature = 0 if not overridden (line 102 in AnthropicProvider.swift)
			return 0.0
		case .customProvider:
			// CustomProviderConfiguration uses 0.3 as default (line 10 in CustomProviderConfiguration.swift)
			return 0.3
		case .openAI, .azure, .openRouter, .gemini, .deepseek, .fireworks, .grok, .groq, .zAI, .claudeCode, .codex, .ollama, .geminiCli, .openCode, .cursor:
			// These providers don't set temperature when nil - API uses its own default (typically 1.0)
			// But we can't be certain what the API actually used
			return nil
		}
	}
}
