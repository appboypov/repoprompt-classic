import Foundation

/// Structured tags for model discovery. Helps callers programmatically
/// choose the right model for their task without parsing descriptions.
enum AgentModelDiscoveryTag: String, CaseIterable, Sendable {
	case fast
	case exploration
	case balanced
	case engineering
	case complex
	case pair
	case extendedContext = "extended_context"

	/// Fixed display order for deterministic output.
	static let displayOrder: [AgentModelDiscoveryTag] = allCases

	/// Dynamic models are intentionally untagged. Tags are reserved for the
	/// small set of explicit recommendation targets below.
	static func infer(from _: String) -> [AgentModelDiscoveryTag] {
		[]
	}
}

enum AgentModel: String, CaseIterable, Codable {
	// GPT-5.1 Codex Mini (separate fast model)
	case codexMini = "gpt-5.1-codex-mini"

	// GPT-5.5 models exposed through Codex CLI
	case gpt55CodexLow = "gpt-5.5-low"
	case gpt55CodexMedium = "gpt-5.5-medium"
	case gpt55CodexHigh = "gpt-5.5-high"
	case gpt55CodexXHigh = "gpt-5.5-xhigh"

	// GPT-5.3 Codex models - uses gpt-5.3-codex (agentic coding optimized)
	case codexLow = "gpt-5.3-codex-low"
	case codexMedium = "gpt-5.3-codex-medium"
	case codexHigh = "gpt-5.3-codex-high"
	case codexXHigh = "gpt-5.3-codex-xhigh"

	// GPT-5.2 models (base model with reasoning levels)
	case gpt5Low = "gpt-5.2-low"
	case gpt5Medium = "gpt-5.2-medium"
	case gpt5High = "gpt-5.2-high"
	case gpt5XHigh = "gpt-5.2-xhigh"

	// GPT-5.4 models
	case gpt54Low = "gpt-5.4-low"
	case gpt54Medium = "gpt-5.4-medium"
	case gpt54High = "gpt-5.4-high"
	case gpt54XHigh = "gpt-5.4-xhigh"

	// GPT-5.4 Mini models (separate fast model family)
	case gpt54MiniLow = "gpt-5.4-mini-low"
	case gpt54MiniMedium = "gpt-5.4-mini-medium"
	case gpt54MiniHigh = "gpt-5.4-mini-high"

	// Claude Code models
	case claudeSonnet = "sonnet"
	case claudeOpus = "opus"
	case claudeHaiku = "haiku"
	case claudeOpus1m = "opus[1m]"

	// Claude Code full model IDs (static known versions; no dynamic probing)
	case claudeSonnet46 = "claude-sonnet-4-6"
	case claudeSonnet45 = "claude-sonnet-4-5"
	case claudeOpus47 = "claude-opus-4-7"
	case claudeOpus46 = "claude-opus-4-6"
	case claudeOpus45 = "claude-opus-4-5"
	case claudeHaiku45 = "claude-haiku-4-5"

	// Claude Code GLM aliases
	case glm46 = "glm-4.6" // legacy compatibility only
	case glm47 = "glm-4.7"
	case glm5Turbo = "glm-5-turbo"
	case glm5 = "glm-5.1"

	// Claude-compatible backend no-model display entries
	case kimiCode = "kimi-code"
	case customClaudeCompatible = "custom-claude-compatible"

	// Gemini models
	case geminiFlash25 = "gemini-2.5-flash"
	case geminiPro25 = "gemini-2.5-pro"
	case geminiPro3p1Preview = "gemini-3.1-pro-preview"
	case gemini3FlashPreview = "gemini-3-flash-preview"

	// Cursor models
	case cursorAuto = "auto"
	case cursorComposer2 = "composer-2"

	// Default (no model specified)
	case defaultModel = "default"

	var displayName: String {
		switch self {
		case .codexMini: return "GPT-5.1 Codex Mini"
		case .gpt55CodexLow: return "GPT-5.5 Low"
		case .gpt55CodexMedium: return "GPT-5.5 Medium"
		case .gpt55CodexHigh: return "GPT-5.5 High"
		case .gpt55CodexXHigh: return "GPT-5.5 XHigh"
		case .codexLow: return "GPT-5.3 Codex Low"
		case .codexMedium: return "GPT-5.3 Codex Medium"
		case .codexHigh: return "GPT-5.3 Codex High"
		case .codexXHigh: return "GPT-5.3 Codex XHigh"
		case .gpt5Low: return "GPT-5.2 Low"
		case .gpt5Medium: return "GPT-5.2 Medium"
		case .gpt5High: return "GPT-5.2 High"
		case .gpt5XHigh: return "GPT-5.2 XHigh"
		case .gpt54Low: return "GPT-5.4 Low"
		case .gpt54Medium: return "GPT-5.4 Medium"
		case .gpt54High: return "GPT-5.4 High"
		case .gpt54XHigh: return "GPT-5.4 XHigh"
		case .gpt54MiniLow: return "GPT-5.4 Mini Low"
		case .gpt54MiniMedium: return "GPT-5.4 Mini Medium"
		case .gpt54MiniHigh: return "GPT-5.4 Mini High"
		case .claudeSonnet: return "Sonnet Latest"
		case .claudeOpus: return "Opus Latest"
		case .claudeHaiku: return "Haiku Latest"
		case .claudeOpus1m: return "Opus Latest (1M)"
		case .claudeSonnet46: return "Sonnet 4.6"
		case .claudeSonnet45: return "Sonnet 4.5"
		case .claudeOpus47: return "Opus 4.7"
		case .claudeOpus46: return "Opus 4.6"
		case .claudeOpus45: return "Opus 4.5"
		case .claudeHaiku45: return "Haiku 4.5"
		case .glm46: return "GLM 4.6"
		case .glm47: return "GLM 4.7"
		case .glm5Turbo: return "GLM 5 Turbo"
		case .glm5: return "GLM 5.1"
		case .kimiCode: return "Kimi Code"
		case .customClaudeCompatible: return "CC Custom"
		case .geminiFlash25: return "Gemini Flash 2.5"
		case .geminiPro25: return "Gemini Pro 2.5"
		case .geminiPro3p1Preview: return "Gemini Pro 3.1 Preview"
		case .gemini3FlashPreview: return "Gemini Flash 3.0 Preview"
		case .cursorAuto: return "Auto"
		case .cursorComposer2: return "Composer 2"
		case .defaultModel: return "Default"
		}
	}

	var description: String {
		switch self {
		case .codexMini: return "Ultra-fast. Good for quick lookups, simple edits, and surface-level exploration."
		case .gpt55CodexLow: return "Fast GPT-5.5 reasoning through Codex. Recommended for explore, discovery, and repeated context building."
		case .gpt55CodexMedium: return "Balanced GPT-5.5 reasoning through Codex. Recommended for engineer agents and default implementation work."
		case .gpt55CodexHigh: return "Deep GPT-5.5 reasoning through Codex. Recommended for planning, review, and pair-agent work."
		case .gpt55CodexXHigh: return "Maximum GPT-5.5 reasoning through Codex. Use selectively for the hardest agentic tasks."
		case .codexLow: return "Fast agentic coding. Good for well-scoped, straightforward tasks."
		case .codexMedium: return "Balanced agentic coding. Good for general engineering work with clear requirements."
		case .codexHigh: return "Deep reasoning for complex coding. Best for multi-file refactors and nuanced engineering."
		case .codexXHigh: return "Maximum reasoning. Best for the hardest agentic tasks requiring deep analysis."
		case .gpt5Low: return "Quick responses. Good for exploration and mapping the territory."
		case .gpt5Medium: return "Balanced reasoning. Good for general-purpose tasks."
		case .gpt5High: return "Deep reasoning. Good for complex multi-step problems."
		case .gpt5XHigh: return "Maximum reasoning. Best for the most complex tasks."
		case .gpt54Low: return "Quick GPT-5.4 responses. Good for exploration and light tasks."
		case .gpt54Medium: return "Balanced GPT-5.4. Good for general work with solid reasoning."
		case .gpt54High: return "Deep GPT-5.4 reasoning. Good for complex engineering and analysis."
		case .gpt54XHigh: return "Maximum GPT-5.4 reasoning. Best for the hardest multi-step tasks."
		case .gpt54MiniLow: return "Fast GPT-5.4 Mini. Good for quick exploration and lookups."
		case .gpt54MiniMedium: return "GPT-5.4 Mini with balanced reasoning. Best exploration sub-agent for context gathering."
		case .gpt54MiniHigh: return "GPT-5.4 Mini with deep reasoning. Good for complex exploration and analysis."
		case .claudeSonnet: return "Balanced speed and capability. Good for general coding, analysis, and everyday work."
		case .claudeOpus: return "Strongest Claude model. Best for open-ended tasks, architecture, and complex reasoning."
		case .claudeHaiku: return "Fast and lightweight. Good for exploration, quick edits, and mapping codebases."
		case .claudeOpus1m: return "Claude Opus with 1M token context. Best for large codebases and tasks requiring extensive context."
		case .claudeSonnet46: return "Pinned Claude Sonnet 4.6. Balanced speed and capability for everyday engineering."
		case .claudeSonnet45: return "Pinned Claude Sonnet 4.5. Balanced speed and capability for everyday engineering."
		case .claudeOpus47: return "Pinned Claude Opus 4.7. Strongest Claude tier for complex reasoning and architecture."
		case .claudeOpus46: return "Pinned Claude Opus 4.6. Strongest Claude tier for complex reasoning and architecture."
		case .claudeOpus45: return "Pinned Claude Opus 4.5. Strongest Claude tier for complex reasoning and architecture."
		case .claudeHaiku45: return "Pinned Claude Haiku 4.5. Fast and lightweight for quick edits and exploration."
		case .glm46: return "Legacy GLM tier alias kept for compatibility."
		case .glm47: return "GLM tier via Z.ai. Fast and lightweight, good for exploration."
		case .glm5Turbo: return "GLM tier via Z.ai. Balanced, good for general work."
		case .glm5: return "GLM 5.1 tier via Z.ai. Strongest GLM tier, good for complex tasks."
		case .kimiCode: return "Kimi Code backend. RepoPrompt does not pass a model flag."
		case .customClaudeCompatible: return "Custom Claude-compatible backend. RepoPrompt does not pass a model flag when configured for no-model behavior."
		case .geminiFlash25: return "Legacy Gemini 2.5 Flash kept for compatibility; prefer Gemini Flash 3.0 for exploration."
		case .geminiPro25: return "Legacy Gemini 2.5 Pro kept for compatibility; prefer Gemini 3.1 Pro for complex analysis."
		case .geminiPro3p1Preview: return "Latest Gemini Pro. Enhanced capabilities for complex work."
		case .gemini3FlashPreview: return "Fast next-gen Gemini. Good for exploration and rapid iteration."
		case .cursorAuto: return "Let Cursor choose the best model automatically. Built-in fallback for Cursor ACP runs when dynamic model metadata is unavailable."
		case .cursorComposer2: return "Cursor's Composer 2 model. Available when Cursor exposes it through ACP model metadata."
		case .defaultModel: return "Use the agent's default model. Good starting point when unsure."
		}
	}

	// Get available models for a specific agent type
	static func modelsForAgent(_ agentKind: DiscoverAgentKind) -> [AgentModel] {
		let models: [AgentModel]
		switch agentKind {
		case .codexExec:
			models = [.defaultModel,
					.gpt55CodexLow, .gpt55CodexMedium, .gpt55CodexHigh, .gpt55CodexXHigh,
					.codexMini, .codexLow, .codexMedium, .codexHigh, .codexXHigh,
					.gpt54MiniLow, .gpt54MiniMedium, .gpt54MiniHigh,
					.gpt54Low, .gpt54Medium, .gpt54High, .gpt54XHigh,
					.gpt5Low, .gpt5Medium, .gpt5High, .gpt5XHigh]
		case .claudeCode:
			// Family priority matches the Claude Code picker catalog:
			// Opus[1M] → Opus → Sonnet → Haiku. Within each family,
			// latest aliases come first, then pinned full IDs by descending version.
			models = [
				.defaultModel,
				.claudeOpus1m,
				.claudeOpus, .claudeOpus47, .claudeOpus46, .claudeOpus45,
				.claudeSonnet, .claudeSonnet46, .claudeSonnet45,
				.claudeHaiku, .claudeHaiku45,
			]
		case .gemini:
			models = [.defaultModel, .gemini3FlashPreview, .geminiPro3p1Preview, .geminiFlash25, .geminiPro25]
		case .openCode:
			models = [.defaultModel]
		case .cursor:
			models = [.cursorAuto, .cursorComposer2]
		case .claudeCodeGLM:
			models = [.claudeHaiku, .claudeSonnet, .claudeOpus]
		case .kimiCode:
			models = [.kimiCode]
		case .customClaudeCompatible:
			models = [.customClaudeCompatible]
		}
		return models.filter { $0.isAvailable }
	}

	// Check if this model is valid for the given agent
	func isValidFor(_ agentKind: DiscoverAgentKind) -> Bool {
		AgentModel.modelsForAgent(agentKind).contains(self)
	}

	/// Resolve a stored model raw string to the closest known model enum for UI bindings.
	/// Codex dynamic model IDs can arrive as base-only IDs (for example `gpt-5.3-codex`)
	/// which are valid to run but don't map directly to enum cases.
	static func resolvedModel(forRaw rawModel: String?, agentKind: DiscoverAgentKind) -> AgentModel? {
		guard let rawModel else { return nil }
		let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty else { return nil }

		if agentKind.usesClaudeTooling {
			let specifier = ClaudeModelSpecifier(raw: normalized)
			guard let baseModel = specifier.baseModel else {
				return agentKind == .claudeCode ? .defaultModel : nil
			}
			if agentKind == .kimiCode,
				baseModel.caseInsensitiveCompare(AgentModel.kimiCode.rawValue) == .orderedSame {
				return .kimiCode
			}
			if agentKind == .customClaudeCompatible {
				if baseModel.caseInsensitiveCompare(AgentModel.customClaudeCompatible.rawValue) == .orderedSame {
					return .customClaudeCompatible
				}
				if let slotModel = AgentModel(rawValue: baseModel), [.claudeHaiku, .claudeSonnet, .claudeOpus].contains(slotModel) {
					return slotModel
				}
			}
			if agentKind == .claudeCodeGLM,
				let mappedRaw = ClaudeCodeGLMIntegration.normalizedGLMModel(baseModel),
				let mapped = AgentModel(rawValue: mappedRaw),
				mapped.isValidFor(agentKind) {
				return mapped
			}
			if let exact = AgentModel(rawValue: baseModel), exact.isValidFor(agentKind) {
				return exact
			}
			return nil
		}

		if agentKind == .gemini,
			normalized.caseInsensitiveCompare("gemini-3-pro-preview") == .orderedSame {
			return .geminiPro3p1Preview
		}

		if let exact = AgentModel(rawValue: normalized), exact.isValidFor(agentKind) {
			return exact
		}

		guard agentKind == .codexExec else { return nil }
		let specifier = CodexModelSpecifier(raw: normalized)
		let base = (specifier.baseModel ?? normalized).lowercased()
		let effort = specifier.reasoningEffort

		func codex53(for effort: CodexReasoningEffort?) -> AgentModel {
			switch effort {
			case .some(.low):
				return .codexLow
			case .some(.high):
				return .codexHigh
			case .some(.xhigh):
				return .codexXHigh
			case .some(.none), .some(.minimal), .some(.medium):
				return .codexMedium
			case nil, .some:
				return .codexMedium
			}
		}

		func gpt52(for effort: CodexReasoningEffort?) -> AgentModel {
			switch effort {
			case .some(.low):
				return .gpt5Low
			case .some(.high):
				return .gpt5High
			case .some(.xhigh):
				return .gpt5XHigh
			case .some(.none), .some(.minimal), .some(.medium):
				return .gpt5Medium
			case nil, .some:
				return .gpt5Medium
			}
		}

		func gpt55(for effort: CodexReasoningEffort?) -> AgentModel {
			switch effort {
			case .some(.low):
				return .gpt55CodexLow
			case .some(.high):
				return .gpt55CodexHigh
			case .some(.xhigh):
				return .gpt55CodexXHigh
			case .some(.none), .some(.minimal), .some(.medium):
				return .gpt55CodexMedium
			case nil, .some:
				return .gpt55CodexMedium
			}
		}

		func gpt54(for effort: CodexReasoningEffort?) -> AgentModel {
			switch effort {
			case .some(.low):
				return .gpt54Low
			case .some(.high):
				return .gpt54High
			case .some(.xhigh):
				return .gpt54XHigh
			case .some(.none), .some(.minimal), .some(.medium):
				return .gpt54Medium
			case nil, .some:
				return .gpt54Medium
			}
		}

		func gpt54Mini(for effort: CodexReasoningEffort?) -> AgentModel {
			switch effort {
			case .some(.low):
				return .gpt54MiniLow
			case .some(.high):
				return .gpt54MiniHigh
			case .some(.none), .some(.minimal), .some(.medium):
				return .gpt54MiniMedium
			case nil, .some:
				return .gpt54MiniMedium
			}
		}

		if base.contains("gpt-5.1-codex-mini") || base.contains("codex-mini") {
			return .codexMini
		}
		if base.contains("gpt-5.3-codex") {
			return codex53(for: effort)
		}
		if base.contains("gpt-5.5") {
			return gpt55(for: effort)
		}
		// Check mini before regular gpt-5.4 to avoid false matches
		if base.contains("gpt-5.4-mini") {
			return gpt54Mini(for: effort)
		}
		if base.contains("gpt-5.4") {
			return gpt54(for: effort)
		}
		if base.contains("gpt-5.2") {
			return gpt52(for: effort)
		}
		if base.contains("codex") {
			return codex53(for: effort)
		}
		if base.contains("gpt-5") {
			return gpt52(for: effort)
		}

		return nil
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let decodedRawValue = try container.decode(String.self)
		if decodedRawValue.lowercased() == "glm-5" {
			self = .glm5
			return
		}
		if let model = AgentModel(rawValue: decodedRawValue) {
			self = model
			return
		}
		throw DecodingError.dataCorruptedError(
			in: container,
			debugDescription: "Invalid AgentModel raw value: \(decodedRawValue)"
		)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	/// Whether this model uses the 1M extended context window.
	var isExtendedContext: Bool {
		switch self {
		case .claudeOpus1m:
			return true
		default:
			return false
		}
	}

	/// Returns the release date for models with staged rollouts
	var availableFrom: Date? {
		return nil
	}

	/// Check if a model is currently available based on its release date
	var isAvailable: Bool {
		if let releaseDate = availableFrom {
			return Date() >= releaseDate
		}
		return true
	}

	/// Structured tags indicating when this model is one of the explicit
	/// recommendation targets. Other models are intentionally untagged.
	var discoveryTags: [AgentModelDiscoveryTag] {
		switch self {
		case .gpt55CodexLow:
			return [.fast, .exploration]
		case .gpt55CodexMedium:
			return [.engineering]
		case .gpt55CodexHigh:
			return [.complex, .engineering, .pair]
		case .claudeOpus:
			return [.complex, .engineering, .pair]
		default:
			return []
		}
	}

	/// Known context window size in tokens, when verified.
	/// Returns `nil` for models where the context window is unknown or unverified.
	var contextWindowTokens: Int? {
		switch self {
		case .claudeOpus1m:
			return 1_000_000
		case .claudeSonnet, .claudeOpus, .claudeHaiku,
			.claudeSonnet46, .claudeSonnet45,
			.claudeOpus47, .claudeOpus46, .claudeOpus45,
			.claudeHaiku45:
			return 200_000
		default:
			return nil
		}
	}
}
